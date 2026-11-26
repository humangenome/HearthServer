using Hearth.SourceQuery;
using HearthServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Runs the Source A2S query responder. Pulls live snapshot data from the plugin
/// (via <see cref="ServerState"/>) on every query, so external tools like
/// GameTracker and ServerMonkey see real player counts.
/// </summary>
public sealed class SourceQueryHostedService : IHostedService, IAsyncDisposable
{
    private readonly ILogger<SourceQueryHostedService> _log;
    private readonly HearthServerOptions _opts;
    private readonly ServerState _state;
    private SourceQueryServer? _server;

    public SourceQueryHostedService(
        ILogger<SourceQueryHostedService> log,
        IOptions<HearthServerOptions> opts,
        ServerState state)
    {
        _log = log;
        _opts = opts.Value;
        _state = state;
    }

    public Task StartAsync(CancellationToken ct)
    {
        _server = new SourceQueryServer(
            _opts.QueryPort,
            BuildInfo,
            BuildPlayers,
            BuildRules,
            IsGameOnline,
            queryObserver: (type, remote) => _log.LogDebug("A2S query {Type} from {Remote}", type, remote),
            notice: line => _log.LogWarning("{Notice}", line));
        _log.LogInformation("Source A2S query listening on UDP {Port}", _server.BoundPort);
        return _server.StartAsync(ct);
    }

    public async Task StopAsync(CancellationToken _)
    {
        if (_server is not null) await _server.StopAsync().ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_server is not null) await _server.StopAsync().ConfigureAwait(false);
    }

    internal ServerInfoSnapshot BuildInfo() => new(
        Name: string.IsNullOrWhiteSpace(_opts.ServerName) ? $"Hearth — {_opts.InstanceId}" : _opts.ServerName.Trim(),
        Map: "Karvenia_08",
        Folder: "bellwright",
        Game: "Bellwright",
        SteamAppId: 1812450,                          // real Steam AppID — written as 64-bit GameID in EDF
        PlayerCount: _state.EffectivePlayerCount,
        MaxPlayers: _opts.MaxPlayers,
        // The join password the bw_ident host mod enforces (JoinPassword, or the legacy
        // HearthAuthPassword). The Hearth app asks the player for it when this is set.
        PasswordRequired: JoinGateFileService.PasswordRequired(_opts),
        VacSecured: false,
        Version: $"hearth-{HearthVersionInfo.HearthVersion}/bw-{HearthVersionInfo.HearthBuild}",
        GameplayPort: _opts.GameplayPort,
        Keywords: $"hearth,bellwright,hearth={HearthVersionInfo.HearthVersion},bwbuild={HearthVersionInfo.HearthBuild}");

    private IReadOnlyList<PlayerInfoEntry> BuildPlayers()
    {
        // Source A2S player list. We populate from cached
        // PlayerListSnapshot frames the plugin ships over IPC. Each
        // entry maps to (DisplayName, Score=0, ConnectionSeconds since
        // ConnectedAtUnixMs). If the plugin hasn't sent a snapshot yet
        // (or no players are connected) the list is empty — gametracker
        // / panel tools show 'no players online' rather than a faked
        // count.
        var snap = _state.Players;
        if (snap.Count == 0) return Array.Empty<PlayerInfoEntry>();

        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var result = new List<PlayerInfoEntry>(snap.Count);
        foreach (var p in snap)
        {
            var ageMs = nowMs - p.ConnectedAtUnixMs;
            var ageSec = ageMs > 0 ? (float)(ageMs / 1000.0) : 0f;
            result.Add(new PlayerInfoEntry(
                Name: string.IsNullOrEmpty(p.DisplayName) ? p.HearthUserId : p.DisplayName,
                Score: 0,
                ConnectSeconds: ageSec));
        }
        return result;
    }

    private IReadOnlyList<KeyValuePair<string, string>> BuildRules() => new[]
    {
        new KeyValuePair<string, string>("instance", _opts.InstanceId),
        new KeyValuePair<string, string>("gameplay_port", _opts.GameplayPort.ToString()),
        new KeyValuePair<string, string>("hearth_version", HearthVersionInfo.HearthVersion),
        new KeyValuePair<string, string>("hearth_build", HearthVersionInfo.HearthBuild),
    };

    // Online when the Bellwright process named in the pid file is alive.
    private bool IsGameOnline()
    {
        var online = GameProcessProbe.IsAlive(_opts.GamePidFile);
        _log.LogDebug("A2S IsGameOnline={Online} (game process probe)", online);
        return online;
    }
}
