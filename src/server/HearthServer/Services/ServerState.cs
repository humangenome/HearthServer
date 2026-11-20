using Hearth.Protocol;
using Microsoft.Extensions.Logging;

namespace HearthServer.Services;

/// <summary>
/// Who is on the server, shared by A2S, RCON and the HTTP API. Players come from
/// bw_host's roster.json (RosterFileWatcherService) and from the game's own log
/// (HearthLogTailService), merged by id and name. Until v0.1.100 this also held
/// a named-pipe plugin connection; no plugin ever connected, and that part is gone.
/// </summary>
public sealed class ServerState
{
    private readonly ILogger<ServerState> _log;

    public ServerState(ILogger<ServerState> log) => _log = log;

    public int EffectivePlayerCount => Players.Count;

    // Players from roster.json; _logPlayers are the ones seen in the game log.
    private List<PlayerSnapshot> _players = new();
    private readonly Dictionary<string, PlayerSnapshot> _logPlayers = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _playersGate = new();
    public IReadOnlyList<PlayerSnapshot> Players
    {
        get
        {
            lock (_playersGate)
            {
                var merged = new List<PlayerSnapshot>(_players.Count + _logPlayers.Count);
                var seenIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var player in _players.Concat(_logPlayers.Values))
                {
                    var id = player.HearthUserId ?? "";
                    var name = player.DisplayName ?? "";
                    if (id.Length > 0 && !seenIds.Add(id)) continue;
                    if (name.Length > 0 && !seenNames.Add(name)) continue;
                    merged.Add(player);
                }
                return merged;
            }
        }
    }
    public void SetPlayers(IEnumerable<PlayerSnapshot> players)
    {
        lock (_playersGate) _players = players?.ToList() ?? new();
    }

    public void UpsertLogPlayer(string hearthUserId, string displayName, int pingMs = 0)
    {
        if (string.IsNullOrWhiteSpace(displayName)) return;
        var id = string.IsNullOrWhiteSpace(hearthUserId) ? $"bw:{displayName}" : hearthUserId;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        lock (_playersGate)
        {
            var connectedAt = _logPlayers.TryGetValue(id, out var existing)
                ? existing.ConnectedAtUnixMs
                : now;
            _logPlayers[id] = new PlayerSnapshot(id, displayName, connectedAt, now, pingMs);
        }
    }

    public void RemoveLogPlayer(string hearthUserId)
    {
        if (string.IsNullOrWhiteSpace(hearthUserId)) return;
        lock (_playersGate)
        {
            _logPlayers.Remove(hearthUserId);
            _players = _players
                .Where(player => !string.Equals(player.HearthUserId, hearthUserId, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
    }

    public void RemoveLogPlayerByDisplayName(string displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName)) return;
        lock (_playersGate)
        {
            foreach (var key in _logPlayers
                         .Where(kv => string.Equals(kv.Value.DisplayName, displayName, StringComparison.OrdinalIgnoreCase))
                         .Select(kv => kv.Key)
                         .ToList())
            {
                _logPlayers.Remove(key);
            }
            _players = _players
                .Where(player => !string.Equals(player.DisplayName, displayName, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
    }

    public void ClearLogPlayers()
    {
        lock (_playersGate) _logPlayers.Clear();
    }

    internal void SetLogPlayerForTest(PlayerSnapshot player)
    {
        lock (_playersGate) _logPlayers[player.HearthUserId] = player;
    }

    public void ClearLogPlayersIfOnlyOne()
    {
        lock (_playersGate)
        {
            var mergedCount = _players
                .Concat(_logPlayers.Values)
                .GroupBy(player => !string.IsNullOrWhiteSpace(player.DisplayName)
                    ? $"name:{player.DisplayName}"
                    : $"id:{player.HearthUserId}", StringComparer.OrdinalIgnoreCase)
                .Count();
            if (mergedCount <= 1)
            {
                _logPlayers.Clear();
                _players.Clear();
            }
        }
    }

}

/// <summary>
/// Wraps the per-plugin connection: send queue, sequence counter, codec.
/// </summary>
