using Hearth.Protocol;
using Hearth.Rcon;
using HearthServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Source RCON server. Translates RCON commands into <see cref="FrameType.RconCommand"/>
/// frames sent to the plugin and awaits the matching response, with a fallback
/// for purely server-side commands (status, players, save).
/// </summary>
public sealed class RconHostedService : IHostedService
{
    private readonly ILogger<RconHostedService> _log;
    private readonly HearthServerOptions _opts;
    private readonly PipeServerState _state;
    private readonly SaveOrchestratorService _saves;
    private readonly ChatService _chat;
    private RconServer? _server;

    public RconHostedService(
        ILogger<RconHostedService> log,
        IOptions<HearthServerOptions> opts,
        PipeServerState state,
        SaveOrchestratorService saves,
        ChatService chat)
    {
        _log = log;
        _opts = opts.Value;
        _state = state;
        _saves = saves;
        _chat = chat;
    }

    public Task StartAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_opts.RconPassword))
        {
            _log.LogWarning("RCON disabled (no password set in Hearth:RconPassword)");
            return Task.CompletedTask;
        }
        _server = new RconServer(_opts.RconPort, _opts.RconPassword, ExecuteAsync, _log);
        _server.Start(ct);
        _log.LogInformation("RCON listening on TCP {Port}", _server.BoundPort);
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken _)
    {
        if (_server is not null) await _server.StopAsync().ConfigureAwait(false);
    }

    private async Task<string> ExecuteAsync(string command)
    {
        var trimmed = command.Trim();
        if (string.IsNullOrEmpty(trimmed)) return "";

        var parts = trimmed.Split(' ', 2);
        var head = parts[0].ToLowerInvariant();
        var rest = parts.Length > 1 ? parts[1] : "";
        // Log the verb + arg length only — never the raw arg, which may carry
        // chat text or operator-entered content.
        _log.LogDebug("RCON dispatch: cmd={Cmd} argLen={ArgLen}", head, rest.Length);
        return head switch
        {
            "help"     => "commands: status, players, ping, save game, save snapshot, save list, save restore <id>, say <msg>, announce <msg>, motd [msg]",
            "status"   => BuildStatus(),
            "players"  => BuildPlayers(),
            "ping"     => "pong",
            "save"     => await HandleSaveAsync(rest).ConfigureAwait(false),
            "snapshot" => await HandleSaveAsync("snapshot").ConfigureAwait(false),
            "say"      => HandleChat(rest, "system"),
            "announce" => HandleChat(rest, "admin"),
            "motd"     => HandleMotd(rest),
            _          => $"unknown rcon command: {head} (try: help)",
        };
    }

    private string HandleChat(string msg, string channel)
    {
        var clean = (msg ?? "").Trim();
        if (string.IsNullOrEmpty(clean)) return $"usage: {(channel == "admin" ? "announce" : "say")} <message>";
        var entry = _chat.BroadcastFromServer(clean, channel: channel, sender: "Server");
        return $"chat ok ({channel}): {entry.Msg}";
    }

    private string HandleMotd(string sub)
    {
        var trimmed = (sub ?? "").Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            var cur = _chat.GetMotd();
            return string.IsNullOrEmpty(cur) ? "motd is empty" : $"motd: {cur}";
        }
        return _chat.SetMotd(trimmed) ? "motd updated" : "motd update failed (check log)";
    }

    private async Task<string> HandleSaveAsync(string sub)
    {
        var arg = sub.Trim();
        if (arg.Equals("game", StringComparison.OrdinalIgnoreCase))
            return RequestGameSave();
        if (string.IsNullOrEmpty(arg) || arg.Equals("snapshot", StringComparison.OrdinalIgnoreCase))
        {
            // The game host auto-saves to <userdir>/Saved/SaveGames every ~60s.
            // We snapshot the on-disk save file directly; the plugin SaveQuiesce
            // ack is not required because the game's own save writer is atomic
            // (writes to temp then renames). The FileSystemWatcher in
            // SaveOrchestratorService handles auto-snapshots; this RCON path is
            // for admin-triggered.
            var rec = await _saves.SnapshotAsync("rcon").ConfigureAwait(false);
            return rec is null
                ? "snapshot failed (check hearth log; save dir likely missing)"
                : $"snapshot ok: {rec.SnapshotId} ({rec.SizeBytes} bytes, sha={rec.Sha256Hex[..16]})";
        }
        if (arg.Equals("list", StringComparison.OrdinalIgnoreCase))
        {
            var snaps = _saves.Database.ListSnapshots(20);
            if (snaps.Count == 0) return "no snapshots yet";
            var sb = new System.Text.StringBuilder();
            foreach (var s in snaps)
                sb.AppendLine($"{s.SnapshotId}  {s.SizeBytes}B  age={(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - s.TakenUnix)}s  sha={s.Sha256Hex[..16]}");
            return sb.ToString().TrimEnd();
        }
        if (arg.StartsWith("restore ", StringComparison.OrdinalIgnoreCase))
        {
            var snapshotId = arg["restore ".Length..].Trim();
            if (string.IsNullOrEmpty(snapshotId)) return "usage: save restore <id>";
            var restored = await _saves.RestoreSnapshotAsync(snapshotId, "rcon").ConfigureAwait(false);
            return restored
                ? $"restore ok: {snapshotId}"
                : $"restore failed: {snapshotId} (not found, missing, or invalid; check hearth log)";
        }
        return "usage: save game | save snapshot | save list | save restore <id>";
    }

    private string RequestGameSave()
    {
        if (!OperatingSystem.IsWindows())
            return "game save unavailable on this platform";

        try
        {
            var windowsDirectory = Environment.GetEnvironmentVariable("WINDIR") ?? @"C:\Windows";
            var markerPath = GameSaveMarkerPath(_opts.GameplayPort, _opts.GamePidFile, windowsDirectory);
            Directory.CreateDirectory(Path.GetDirectoryName(markerPath)!);
            File.WriteAllText(markerPath, DateTimeOffset.UtcNow.ToString("O"));
            _log.LogInformation("Bellwright game save requested for gameplay port {Port}", _opts.GameplayPort);
            return "game save requested";
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Bellwright game save request failed for gameplay port {Port}", _opts.GameplayPort);
            return "game save request failed (check hearth log)";
        }
    }

    internal static string GameSaveMarkerPath(int gameplayPort, string gamePidFile, string windowsDirectory)
    {
        if (gameplayPort is < 1 or > 65535)
            throw new ArgumentOutOfRangeException(nameof(gameplayPort));
        if (string.IsNullOrWhiteSpace(gamePidFile) && string.IsNullOrWhiteSpace(windowsDirectory))
            throw new ArgumentException("Windows directory is required when no game PID file is configured", nameof(windowsDirectory));

        var markerDirectory = Path.Combine(windowsDirectory, "Temp");
        if (!string.IsNullOrWhiteSpace(gamePidFile))
        {
            var normalizedPidFile = gamePidFile.Trim();
            var separator = Math.Max(normalizedPidFile.LastIndexOf('\\'), normalizedPidFile.LastIndexOf('/'));
            markerDirectory = separator > 0 ? normalizedPidFile[..separator] : "";
        }
        if (string.IsNullOrWhiteSpace(markerDirectory))
            throw new ArgumentException("A marker directory could not be resolved", nameof(gamePidFile));

        return Path.Combine(markerDirectory, $"hearth_force_save_{gameplayPort}.marker");
    }

    private string BuildStatus()
    {
        // Same "online" rule as /api/v1/health: the plugin is pinging or the game process is up.
        // The old "plugin=disconnected" line told an admin nothing about the world.
        var heartbeatTimeout = TimeSpan.FromSeconds(Math.Max(1, _opts.PluginHeartbeatTimeoutSeconds));
        var running = _state.HasFreshHeartbeat(heartbeatTimeout) || GameProcessProbe.IsAlive(_opts.GamePidFile);
        var name = string.IsNullOrWhiteSpace(_opts.ServerName) ? $"Hearth - {_opts.InstanceId}" : _opts.ServerName.Trim();
        return FormatStatus(name, running, _state.EffectivePlayerCount, _opts.MaxPlayers, HearthVersionInfo.HearthVersion);
    }

    private string BuildPlayers() =>
        FormatPlayers(_state.Players, _opts.MaxPlayers, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    internal static string FormatStatus(string serverName, bool worldRunning, int players, int maxPlayers, string version) =>
        $"{serverName}: world {(worldRunning ? "running" : "not running")}, {players} of {maxPlayers} players, Hearth {version}";

    // One line per player: name and time on the server. The reply used to be a count with a
    // builder's note.
    internal static string FormatPlayers(IReadOnlyList<PlayerSnapshot> players, int maxPlayers, long nowUnixMs)
    {
        if (players.Count == 0)
            return "no players online";
        var lines = players.Select(p =>
        {
            var name = string.IsNullOrEmpty(p.DisplayName) ? p.HearthUserId : p.DisplayName;
            return $"{name}  {FormatOnlineFor(nowUnixMs - p.ConnectedAtUnixMs)}";
        });
        return $"{players.Count} of {maxPlayers} players online\n" + string.Join("\n", lines);
    }

    private static string FormatOnlineFor(long ms)
    {
        var minutes = Math.Max(0, ms) / 60_000;
        if (minutes < 1) return "just joined";
        if (minutes < 60) return $"{minutes}m";
        return $"{minutes / 60}h {minutes % 60:00}m";
    }
}
