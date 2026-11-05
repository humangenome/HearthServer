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
    private const int CbValidateAuthTicketResponse = 143;
    private static readonly string[] AuthResponses =
    [
        "OK", "UserNotConnectedToSteam", "NoLicenseOrExpired", "VACBanned", "LoggedInElseWhere", "VACCheckTimedOut",
        "AuthTicketCanceled", "AuthTicketInvalidAlreadyUsed", "AuthTicketInvalid", "PublisherIssuedBan",
        "AuthTicketNetworkIdentityFailure",
    ];
    private static readonly string[] BeginResults = ["OK", "InvalidTicket", "DuplicateRequest", "InvalidVersion", "GameMismatch", "ExpiredTicket"];

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
    private readonly BlockingCollection<Work> _queue = new();
    private readonly Thread _thread;
    private string? _unavailable;

    private sealed record Work(ulong SteamId, byte[] Ticket, TaskCompletionSource<SteamTicketResult> Done, DateTime Deadline);

    public SteamGameServerTicketVerifier(IOptions<HearthServerOptions> options, ILogger<SteamGameServerTicketVerifier> log)
    {
        _log = log;
        _opts = options.Value.Identity;
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
            // A Steam game server needs steamclient64.dll. the Steam API library looks for it by name, so loading it first by
            // full path (its folder supplies tier0_s64 / vstdlib_s64) makes a box without a Steam client work too.
            var client = FindSteamClient(_opts.SteamClientPath);
            if (client is not null) { NativeLibrary.Load(client); _log.LogInformation("Identity: Steam client library {Path}", client); }
            else _log.LogInformation("Identity: no steamclient64.dll found; relying on the Steam API library's own search");
            lib = NativeLibrary.Load(path);
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
            var connectedLogged = false;
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
                        if (id == CbSteamServersConnected && !connectedLogged) { connectedLogged = true; _log.LogInformation("Identity: Steam game-server login OK"); }
                        else if (id == CbSteamServerConnectFailure) _log.LogWarning("Identity: Steam game-server login failed (EResult {R})", Marshal.ReadInt32(param, 0));
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

    internal static string? FindSteamClient(string configured)
    {
        var candidates = new List<string>();
        // Identity:SteamClientPath may name the file or the folder that holds it (the self-host notes say "set their folder").
        if (!string.IsNullOrWhiteSpace(configured))
            candidates.Add(Directory.Exists(configured) ? Path.Combine(configured, "steamclient64.dll") : configured);
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "steamclient64.dll"));
        if (OperatingSystem.IsWindows())
        {
            foreach (var key in new[] { @"SOFTWARE\WOW6432Node\Valve\Steam", @"SOFTWARE\Valve\Steam" })
            {
                try
                {
                    using var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(key);
                    if (k?.GetValue("InstallPath") is string dir) candidates.Add(Path.Combine(dir, "steamclient64.dll"));
                }
                catch (Exception) { }
            }
        }
        return candidates.FirstOrDefault(File.Exists);
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
