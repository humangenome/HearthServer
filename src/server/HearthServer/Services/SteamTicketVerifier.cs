using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using HearthServer.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

public enum SteamTicketOutcome
{
    Ok,
    Refused,      // Steam (or the ticket check) said no; Detail says why
    Unavailable,  // no Steam library, no anonymous logon, or no answer in time: fail closed
}

public sealed record SteamTicketResult(SteamTicketOutcome Outcome, string Detail);

public interface ISteamTicketVerifier
{
    Task<SteamTicketResult> VerifyAsync(string steam64, byte[] ticket, CancellationToken ct);
}

/// <summary>
/// Checks a player's Steam session ticket the way a Steam game server does, with no Steam account: an anonymous
/// game-server login for Bellwright (SteamInternal_GameServer_Init_V2 + LogOnAnonymous), then BeginAuthSession and
/// Steam's ValidateAuthTicketResponse_t. Proven on 2026-10-29 with Bellwright's own Steam API library (Steamworks 1.61):
/// anonymous logon for 1812450 works, a real ticket is accepted, the same ticket for another Steam ID and a changed
/// ticket are refused (InvalidTicket). A result is only Ok after Steam's ValidateAuthTicketResponse says OK for that
/// Steam ID; no answer within the timeout fails closed. One dedicated thread owns every Steam call and pumps callbacks.
/// </summary>
public sealed class SteamGameServerTicketVerifier : ISteamTicketVerifier, IDisposable
{
    private const int CbSteamServersConnected = 101;
    private const int CbSteamServerConnectFailure = 102;
    private const int CbSteamServersDisconnected = 103;
    private const int CbValidateAuthTicketResponse = 143;
    private static readonly string[] AuthResponses =
    [
        "OK", "UserNotConnectedToSteam", "NoLicenseOrExpired", "VACBanned", "LoggedInElseWhere", "VACCheckTimedOut",
        "AuthTicketCanceled", "AuthTicketInvalidAlreadyUsed", "AuthTicketInvalid", "PublisherIssuedBan",
        "AuthTicketNetworkIdentityFailure",
    ];
    private static readonly string[] BeginResults = ["OK", "InvalidTicket", "DuplicateRequest", "InvalidVersion", "GameMismatch", "ExpiredTicket"];

    internal enum SteamLogin { NeverConnected, Connected, Lost }
    internal enum SteamLoginLine { None, FirstOk, OkAgain, Failed, Lost }

    /// <summary>
    /// Which login line a Steam game-server callback earns, and the login state after it. Steam drops the game-server
    /// login now and then (seen during its Tuesday maintenance, 2026-11-10) and logs back in by itself; until 0.1.99
    /// only the first "login OK" and each failure were logged, so nobody could tell when Steam checks worked again.
    /// Now a drop (callback 103) logs "lost" and the next connect logs "OK again".
    /// </summary>
    internal static SteamLoginLine NextLoginLine(int callbackId, ref SteamLogin state)
    {
        switch (callbackId)
        {
            case CbSteamServersConnected:
                var before = state;
                state = SteamLogin.Connected;
                return before switch
                {
                    SteamLogin.NeverConnected => SteamLoginLine.FirstOk,
                    SteamLogin.Lost => SteamLoginLine.OkAgain,
                    _ => SteamLoginLine.None,
                };
            case CbSteamServerConnectFailure:
                if (state == SteamLogin.Connected) state = SteamLogin.Lost;
                return SteamLoginLine.Failed;
            case CbSteamServersDisconnected:
                if (state != SteamLogin.Connected) return SteamLoginLine.None; // never had it, or already logged as lost
                state = SteamLogin.Lost;
                return SteamLoginLine.Lost;
            default:
                return SteamLoginLine.None;
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void VoidFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int GsInitFn(uint ip, ushort gamePort, ushort queryPort, int mode, [MarshalAs(UnmanagedType.LPStr)] string version, byte[] interfaces, byte[] err);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int PipeFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void RunFrameFn(int pipe);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private delegate bool NextCallbackFn(int pipe, IntPtr msg);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void FreeCallbackFn(int pipe);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr AccessorFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void GsStrFn(IntPtr gs, [MarshalAs(UnmanagedType.LPStr)] string s);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void GsBoolFn(IntPtr gs, [MarshalAs(UnmanagedType.I1)] bool b);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void GsFn(IntPtr gs);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private delegate bool GsBoolGetFn(IntPtr gs);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int BeginAuthFn(IntPtr gs, byte[] ticket, int cb, ulong steamId);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void EndAuthFn(IntPtr gs, ulong steamId);

    private readonly ILogger<SteamGameServerTicketVerifier> _log;
    private readonly IdentityOptions _opts;
    private readonly SteamLibraryGuard _guard;
    private readonly BlockingCollection<Work> _queue = new();
    private readonly Thread _thread;
    private string? _unavailable;

    private sealed record Work(ulong SteamId, byte[] Ticket, TaskCompletionSource<SteamTicketResult> Done, DateTime Deadline);

    public SteamGameServerTicketVerifier(IOptions<HearthServerOptions> options, ILogger<SteamGameServerTicketVerifier> log)
        : this(options, log, new SteamLibraryGuard()) { }

    internal SteamGameServerTicketVerifier(IOptions<HearthServerOptions> options, ILogger<SteamGameServerTicketVerifier> log, SteamLibraryGuard guard)
    {
        _log = log;
        _opts = options.Value.Identity;
        _guard = guard;
        _thread = new Thread(Run) { IsBackground = true, Name = "steam-ticket-check" };
        _thread.Start();
    }

    public Task<SteamTicketResult> VerifyAsync(string steam64, byte[] ticket, CancellationToken ct)
    {
        if (!ulong.TryParse(steam64, out var id) || ticket.Length is < 16 or > 4096)
            return Task.FromResult(new SteamTicketResult(SteamTicketOutcome.Refused, "malformed request"));
        if (_unavailable is not null)
            return Task.FromResult(new SteamTicketResult(SteamTicketOutcome.Unavailable, _unavailable));
        var tcs = new TaskCompletionSource<SteamTicketResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var timeout = TimeSpan.FromSeconds(Math.Clamp(_opts.SteamCheckTimeoutSeconds, 5, 60));
        if (!_queue.TryAdd(new Work(id, ticket, tcs, DateTime.UtcNow + timeout)))
            return Task.FromResult(new SteamTicketResult(SteamTicketOutcome.Unavailable, "checker stopped"));
        ct.Register(() => tcs.TrySetCanceled(ct));
        // The checker may have given up between the first look and the add; nothing would ever answer this one.
        if (_unavailable is { } why) tcs.TrySetResult(new SteamTicketResult(SteamTicketOutcome.Unavailable, why));
        return tcs.Task;
    }

    // The game's own Steamworks folder beside HearthServer; its one 64-bit Steam API library is the one to load.
    internal static string DefaultSteamApiPath()
    {
        var dir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Engine", "Binaries", "ThirdParty", "Steamworks", "Steamv161", "Win64"));
        if (!Directory.Exists(dir)) return dir;
        return Directory.EnumerateFiles(dir, "steam_api*.dll").OrderBy(f => f, StringComparer.OrdinalIgnoreCase).FirstOrDefault() ?? dir;
    }

    private void Run()
    {
        IntPtr lib = IntPtr.Zero;
        try
        {
            var path = string.IsNullOrWhiteSpace(_opts.SteamApiPath) ? DefaultSteamApiPath() : _opts.SteamApiPath;
            if (!File.Exists(path)) { Fail($"no Steam library at {path}"); return; }
            // Steam reads the app id from the environment through the C runtime's copy, taken when the Steam API library loads, so it
            // has to be set BEFORE the library loads (lab 2026-10-30: set after the load, init said "Can't determine AppID").
            // The old value goes back right after init so nothing HearthServer starts later inherits it.
            var oldAppId = Environment.GetEnvironmentVariable("SteamAppId");
            Environment.SetEnvironmentVariable("SteamAppId", _opts.SteamAppId.ToString());
            // A Steam game server needs steamclient64.dll. The Steam API library looks for it by name, so loading it first by
            // full path (with tier0_s64 / vstdlib_s64 from the same folder) makes a box without a Steam client work too.
            // Only Valve-signed files, held open from the check to the load, from a folder no other account can change when
            // this process runs elevated (SteamLibraryGuard); anything else and Steam checks stay off, with no fallback to a
            // search by name.
            var client = _guard.LoadClient(_opts.SteamClientPath);
            if (!client.Ok)
            {
                Environment.SetEnvironmentVariable("SteamAppId", oldAppId);
                Fail("Steam client library refused: " + client.Detail + (_guard.IsElevated
                    ? " (HearthServer runs with administrator rights, so the folder Identity:SteamClientPath names must be one only administrators can change)"
                    : ""));
                return;
            }
            _log.LogInformation("Identity: Steam client library from {Path} (signed by Valve, checked before loading)", client.Detail);
            var api = _guard.LoadApi(path, client.Detail);
            if (!api.Ok)
            {
                Environment.SetEnvironmentVariable("SteamAppId", oldAppId);
                Fail("Steam API library refused: " + api.Detail);
                return;
            }
            lib = api.Handle;
            T F<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(lib, name));

            var dispatchInit = F<VoidFn>("SteamAPI_ManualDispatch_Init");
            var gsInit = F<GsInitFn>("SteamInternal_GameServer_Init_V2");
            var gsPipe = F<PipeFn>("SteamGameServer_GetHSteamPipe");
            var runFrame = F<RunFrameFn>("SteamAPI_ManualDispatch_RunFrame");
            var next = F<NextCallbackFn>("SteamAPI_ManualDispatch_GetNextCallback");
            var free = F<FreeCallbackFn>("SteamAPI_ManualDispatch_FreeLastCallback");
            var gsAccessor = F<AccessorFn>("SteamAPI_SteamGameServer_v015");
            var setProduct = F<GsStrFn>("SteamAPI_ISteamGameServer_SetProduct");
            var setModDir = F<GsStrFn>("SteamAPI_ISteamGameServer_SetModDir");
            var setDedicated = F<GsBoolFn>("SteamAPI_ISteamGameServer_SetDedicatedServer");
            var logOn = F<GsFn>("SteamAPI_ISteamGameServer_LogOnAnonymous");
            var loggedOn = F<GsBoolGetFn>("SteamAPI_ISteamGameServer_BLoggedOn");
            var beginAuth = F<BeginAuthFn>("SteamAPI_ISteamGameServer_BeginAuthSession");
            var endAuth = F<EndAuthFn>("SteamAPI_ISteamGameServer_EndAuthSession");

            var err = new byte[1024];
            var ifaces = Encoding.ASCII.GetBytes("SteamUtils010\0SteamGameServer015\0\0");
            // port 0 = no game or query socket of our own; authentication mode (2), no VAC.
            var init = gsInit(0, 0, 0xFFFF, 2, "1.0.0.0", ifaces, err);
            Environment.SetEnvironmentVariable("SteamAppId", oldAppId);
            if (init != 0) { Fail($"Steam game-server init failed ({init}: {Ascii(err)})"); return; }
            // Manual dispatch is switched on AFTER init (steam_api.h); before init no callback ever arrives (lab 2026-10-30).
            dispatchInit();
            var gs = gsAccessor();
            setProduct(gs, _opts.SteamAppId.ToString());
            setModDir(gs, "bellwright");
            setDedicated(gs, true);
            logOn(gs);
            var pipe = gsPipe();
            _log.LogInformation("Identity: anonymous Steam game-server login started for app {App}", _opts.SteamAppId);

            var pending = new Dictionary<ulong, Work>();
            var msg = Marshal.AllocHGlobal(32);
            var login = SteamLogin.NeverConnected;
            try
            {
                while (true)
                {
                    // callbacks
                    runFrame(pipe);
                    while (next(pipe, msg))
                    {
                        var id = Marshal.ReadInt32(msg, 4);
                        var param = Marshal.ReadIntPtr(msg, 8);
                        if (id is CbSteamServersConnected or CbSteamServerConnectFailure or CbSteamServersDisconnected)
                        {
                            switch (NextLoginLine(id, ref login))
                            {
                                case SteamLoginLine.FirstOk: _log.LogInformation("Identity: Steam game-server login OK"); break;
                                case SteamLoginLine.OkAgain: _log.LogInformation("Identity: Steam game-server login OK again; Steam checks work again"); break;
                                case SteamLoginLine.Failed: _log.LogWarning("Identity: Steam game-server login failed (EResult {R})", Marshal.ReadInt32(param, 0)); break;
                                case SteamLoginLine.Lost: _log.LogWarning("Identity: Steam game-server login lost (EResult {R}); Steam checks wait until it is back", Marshal.ReadInt32(param, 0)); break;
                            }
                        }
                        else if (id == CbValidateAuthTicketResponse)
                        {
                            var who = (ulong)Marshal.ReadInt64(param, 0);
                            var resp = Marshal.ReadInt32(param, 8);
                            if (pending.Remove(who, out var w))
                            {
                                endAuth(gs, who);
                                var name = resp >= 0 && resp < AuthResponses.Length ? AuthResponses[resp] : resp.ToString();
                                // Steam's OK proves who the player is; a family-shared licence is still that player.
                                w.Done.TrySetResult(resp == 0
                                    ? new SteamTicketResult(SteamTicketOutcome.Ok, "Steam: OK")
                                    : new SteamTicketResult(SteamTicketOutcome.Refused, "Steam: " + name));
                            }
                        }
                        free(pipe);
                    }
                    // timeouts
                    var now = DateTime.UtcNow;
                    foreach (var kv in pending.Where(kv => kv.Value.Deadline < now).ToList())
                    {
                        pending.Remove(kv.Key);
                        endAuth(gs, kv.Key);
                        kv.Value.Done.TrySetResult(new SteamTicketResult(SteamTicketOutcome.Unavailable, "no answer from Steam in time"));
                    }
                    // new work
                    while (_queue.TryTake(out var work, pending.Count == 0 ? 100 : 0))
                    {
                        if (work.Done.Task.IsCompleted) continue;
                        if (!loggedOn(gs)) { work.Done.TrySetResult(new SteamTicketResult(SteamTicketOutcome.Unavailable, "Steam game-server login not up")); continue; }
                        if (pending.ContainsKey(work.SteamId)) { work.Done.TrySetResult(new SteamTicketResult(SteamTicketOutcome.Refused, "a check for this Steam ID is already running")); continue; }
                        var begin = beginAuth(gs, work.Ticket, work.Ticket.Length, work.SteamId);
                        if (begin != 0)
                        {
                            work.Done.TrySetResult(new SteamTicketResult(SteamTicketOutcome.Refused,
                                "ticket: " + (begin < BeginResults.Length ? BeginResults[begin] : begin.ToString())));
                            continue;
                        }
                        pending[work.SteamId] = work;
                    }
                    if (pending.Count > 0) Thread.Sleep(50);
                    if (_queue.IsAddingCompleted && _queue.Count == 0 && pending.Count == 0) break;
                }
            }
            finally { Marshal.FreeHGlobal(msg); }
        }
        catch (Exception ex)
        {
            Fail("Steam check failed: " + ex.Message);
        }
    }

    // Where the client files would come from (the guard's folder choice): the configured file or folder only. null when
    // none is configured or it is not there (no other folder is searched).
    internal static string? FindSteamClient(string configured)
    {
        var folder = new SteamLibraryGuard().ClientFolder(configured);
        return folder is null ? null : Path.Combine(folder, "steamclient64.dll");
    }

    private void Fail(string why)
    {
        _unavailable = why;
        _log.LogWarning("Identity: Steam ticket checks unavailable: {Why}", why);
        while (_queue.TryTake(out var w)) w.Done.TrySetResult(new SteamTicketResult(SteamTicketOutcome.Unavailable, why));
    }

    private static string Ascii(byte[] b)
    {
        var n = Array.IndexOf(b, (byte)0);
        return Encoding.ASCII.GetString(b, 0, n < 0 ? b.Length : n);
    }

    public void Dispose() => _queue.CompleteAdding();
}
