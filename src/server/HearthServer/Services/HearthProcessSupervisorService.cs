using System.Diagnostics;
using System.Text.Json;
using HearthServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Launches Bellwright with UE4SS attached, patches the user-scope Engine.ini
/// for the IpNetDriver override on every launch, watches the process, restarts
/// on unexpected exit.
///
/// Crash policy: if Bellwright exits within MinHealthyUptimeSeconds, treat as
/// "boot loop" and back off exponentially. After a stable run, exit codes
/// reset the backoff.
///
/// In the SurvivalServers panel-managed deploy the SS PowerShell owns the
/// game lifecycle, so GameInstallRoot/GameExecutablePath are left EMPTY and
/// this supervisor stays idle (it returns immediately from ExecuteAsync).
/// </summary>
public sealed class HearthProcessSupervisorService : BackgroundService
{
    private readonly ILogger<HearthProcessSupervisorService> _log;
    private readonly HearthServerOptions _opts;
    private readonly HmacKeyService _hmac;
    private readonly HearthRestartCoordinator _coordinator;

    private const int MinHealthyUptimeSeconds = 60;
    private const int MaxBackoffSeconds = 300;
    public const string HearthCanonicalSaveSlot = "savegame_0";
    // Bellwright opens the real world map directly via the NewGameMapName reflection
    // prop (stock = Karvenia_08) — no save / new-game dance.
    private const string HearthMapPath = "Karvenia_08";
    // Bellwright ships ONE shipping exe (host + client). The packaged project dir
    // follows the .uproject name "Bellwright"; "Mist" is the UE module name, probed
    // defensively in case a package nests under it.
    private static readonly string[][] HearthExeRelativePaths =
    [
        ["Bellwright", "Binaries", "Win64", "BellwrightGame-Win64-Shipping.exe"],
        ["Mist", "Binaries", "Win64", "BellwrightGame-Win64-Shipping.exe"],
        ["Binaries", "Win64", "BellwrightGame-Win64-Shipping.exe"],
        ["BellwrightGame-Win64-Shipping.exe"],
    ];
    public HearthProcessSupervisorService(
        ILogger<HearthProcessSupervisorService> log,
        IOptions<HearthServerOptions> opts,
        HmacKeyService hmac,
        HearthRestartCoordinator coordinator)
    {
        _log = log;
        _opts = opts.Value;
        _hmac = hmac;
        _coordinator = coordinator;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if ((string.IsNullOrEmpty(_opts.GameInstallRoot) && string.IsNullOrEmpty(_opts.GameExecutablePath))
            || !OperatingSystem.IsWindows())
        {
            _log.LogWarning("Process supervisor idle: Bellwright executable not configured or not on Windows");
            return;
        }

        var backoffSeconds = 1;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                // Wait for any in-flight restore to finish before relaunching.
                // The restore code holds the gate while it mutates SaveGames;
                // launching Bellwright while that's in progress would race the file
                // copy and corrupt the world.
                await _coordinator.WaitForNoRestoreAsync(stoppingToken).ConfigureAwait(false);

                ApplyEngineIniPatch();
                EmitPluginConfig();
                var start = DateTime.UtcNow;

                using var proc = LaunchGame();
                _log.LogInformation("Bellwright launched: pid={Pid}", proc.Id);
                while (!stoppingToken.IsCancellationRequested && !proc.HasExited)
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), stoppingToken).ConfigureAwait(false);
                }
                if (stoppingToken.IsCancellationRequested)
                {
                    if (!proc.HasExited)
                    {
                        _log.LogInformation("Stopping — sending Ctrl+C / Close to Bellwright (pid={Pid})", proc.Id);
                        try { proc.CloseMainWindow(); } catch { }
                        if (!proc.WaitForExit(10_000)) proc.Kill(true);
                    }
                    return;
                }

                var uptime = DateTime.UtcNow - start;
                _log.LogWarning("Bellwright exited code={Code} uptime={Uptime}s", proc.ExitCode, (int)uptime.TotalSeconds);

                if (uptime.TotalSeconds >= MinHealthyUptimeSeconds)
                {
                    backoffSeconds = 1; // stable run — reset backoff
                }
                else
                {
                    backoffSeconds = Math.Min(MaxBackoffSeconds, backoffSeconds * 2);
                    _log.LogWarning("Boot-loop suspected — backing off {Seconds}s before restart", backoffSeconds);
                    try { await Task.Delay(TimeSpan.FromSeconds(backoffSeconds), stoppingToken).ConfigureAwait(false); }
                    catch (OperationCanceledException) { return; }
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                _log.LogError(ex, "Supervisor loop error — retry in 5s");
                try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    private Process LaunchGame()
    {
        var exe = ResolveG2ExecutablePath(_opts);
        if (!File.Exists(exe))
            throw new FileNotFoundException($"Bellwright binary not found at {exe}");

        var args = string.Join(' ',
            $"-USERDIR={EscapeArg(_opts.GameUserDir)}",
            "-nullrhi",
            "-unattended",
            $"-port={_opts.GameplayPort}",
            "-log",
            BuildHostTravelUrl());

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = false,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        psi.EnvironmentVariables["HEARTH_INSTANCE"] = _opts.InstanceId;
        return Process.Start(psi) ?? throw new InvalidOperationException("Process.Start returned null");
    }

    private void ApplyEngineIniPatch()
    {
        // Refuse to patch into a user directory that overlaps a vanilla
        // Bellwright install. This catches the case where GameUserDir was
        // accidentally pointed at the customer's Steam Bellwright root and would
        // otherwise overwrite their vanilla Engine.ini.
        if (LooksLikeVanillaG2Path(_opts.GameUserDir))
        {
            _log.LogError("Engine.ini patch refused: GameUserDir={Dir} looks like a vanilla Bellwright install path. " +
                          "Hearth's user dir must be a separate folder (e.g. C:\\sspanel\\gameservers\\bellwright\\<id>\\UserDir).",
                          _opts.GameUserDir);
            return;
        }

        var configDir = Path.Combine(_opts.GameUserDir, "Saved", "Config", "Windows");
        Directory.CreateDirectory(configDir);
        var enginePath = Path.Combine(configDir, "Engine.ini");

        const string driver = "/Script/OnlineSubsystemUtils.IpNetDriver";
        var content = $"""
        ; Hearth-managed Engine.ini override — rewritten on every host launch.
        [OnlineSubsystem]
        DefaultPlatformService=Null

        [OnlineSubsystemNull]
        bSimulateForwarded=true

        [/Script/Engine.GameEngine]
        !NetDriverDefinitions=ClearArray
        +NetDriverDefinitions=(DefName="GameNetDriver",DriverClassName="{driver}",DriverClassNameFallback="{driver}")

        [/Script/EngineSettings.GameMapsSettings]
        LocalMapOptions={BuildHostTravelOptions()}

        [/Script/OnlineSubsystemUtils.IpNetDriver]
        AllowPeerConnections=false
        AllowPeerVoice=false
        bClampListenServerTickRate=true
        NetServerMaxTickRate=60
        MaxClientRate=15000
        MaxInternetClientRate=10000
        NetConnectionTimeout=60
        InitialConnectTimeout=300.0
        ConnectionTimeout=60.0
        ServerTravelPause=4

        [URL]
        Port={_opts.GameplayPort}
        """;
        File.WriteAllText(enginePath, content);
        _log.LogInformation("Patched Engine.ini at {Path}", enginePath);
    }

    private void EmitPluginConfig()
    {
        var exe = ResolveG2ExecutablePath(_opts);
        var pluginDir = Path.Combine(Path.GetDirectoryName(exe)!,
            "Mods", "Hearth");
        Directory.CreateDirectory(pluginDir);
        var configPath = Path.Combine(pluginDir, "hearth.config.json");

        // ServerPassword is INTENTIONALLY emitted empty.
        // The native Hearth.dll ApproveLogin hook would otherwise try to
        // enforce, but the game's stock GameMode races with it and fatal-
        // crashes the dedicated process on host spawn (the ?Password=
        // option in the launch URL is dropped by the game's internal map
        // travel from the menu -> the play level, leaving the host's URL
        // with no password while the native check still expects one).
        // Password enforcement now lives in HearthAuth.lua's K2_PostLogin
        // hook, which gates remote clients only and exempts the listen host.
        // Plugin sees no ServerPassword -> treats the server as open ->
        // no native enforcement -> no crash loop. _opts.ServerPassword
        // is the legacy field; _opts.HearthAuthPassword is what
        // HearthAuth.lua reads from appsettings.json directly.
        var payload = new
        {
            InstanceId = _opts.InstanceId,
            PipePath = $@"\\.\pipe\{_opts.PipeName}",
            HmacKeyHex = Convert.ToHexString(_hmac.Key),
            ServerPassword = "",
        };
        File.WriteAllText(configPath, JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true }));
        _log.LogInformation("Emitted plugin config at {Path}", configPath);
    }

    private static string EscapeArg(string s) => s.Contains(' ') ? $"\"{s}\"" : s;

    internal static string ResolveG2ExecutablePath(HearthServerOptions opts)
    {
        if (!string.IsNullOrWhiteSpace(opts.GameExecutablePath))
        {
            return Path.GetFullPath(opts.GameExecutablePath);
        }

        foreach (var relativePath in HearthExeRelativePaths)
        {
            var candidate = Path.Combine([opts.GameInstallRoot, .. relativePath]);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return Path.Combine([opts.GameInstallRoot, .. HearthExeRelativePaths[0]]);
    }

    public static string BuildHostTravelUrl(string saveSlot = HearthCanonicalSaveSlot)
        => HearthMapPath + BuildHostTravelOptions(saveSlot);

    public static string BuildHostTravelOptions(string saveSlot = HearthCanonicalSaveSlot)
    {
        // Bellwright opens NewGameMapName directly as a listen world — no save /
        // new-game load dance. saveSlot is accepted for API parity but the host
        // travel URL is just the listen option.
        return "?listen";
    }

    /// <summary>
    /// Heuristic: does this path look like a Steam / Epic / MS Store install
    /// root for vanilla Bellwright? Used to refuse Engine.ini / plugin-config
    /// writes that would corrupt a vanilla install if GameUserDir/GameInstallRoot
    /// were misconfigured.
    /// </summary>
    internal static bool LooksLikeVanillaG2Path(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        // Check the resolved real target too — a customer can junction
        // their Hearth user dir at C:\Hearth\userdir over a vanilla
        // Bellwright install and the literal-string check passes while the
        // Engine.ini write lands inside the vanilla folder.
        return MatchesVanillaSubstring(path)
            || MatchesVanillaSubstring(TryResolveSymlinkTarget(path));
    }

    private static bool MatchesVanillaSubstring(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var p = path.Replace('/', '\\').ToLowerInvariant();
        return p.Contains(@"\steamapps\common\")
            || p.Contains(@"\steamlibrary\")
            || p.Contains(@"\epicgameslauncher\")
            || p.Contains(@"\epic games\")
            || p.Contains(@"\windowsapps\");
    }

    private static string? TryResolveSymlinkTarget(string path)
    {
        try
        {
            // DirectoryInfo.LinkTarget on .NET 6+ returns the immediate
            // target of a junction/symlink; null otherwise. Path.GetFullPath
            // canonicalises any '..' segments. ResolveLinkTarget(true)
            // walks the chain (multiple junctions) but isn't strictly
            // needed for the common case.
            var di = new DirectoryInfo(path);
            if (!di.Exists) return null;
            var resolved = di.ResolveLinkTarget(true);
            return resolved?.FullName;
        }
        catch { return null; }
    }
}
