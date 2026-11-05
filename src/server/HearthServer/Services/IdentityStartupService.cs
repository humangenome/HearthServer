using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace HearthServer.Services;

/// <summary>
/// Once, the first time a server runs with the identity feature: seeds the Steam-to-first-computer map from the logs
/// HearthServer still has (its own logs/hearth-*.log, 14 days, and the launcher's Logs\hearthserver.log), so players
/// who already have a character keep their first computer's character when they move to a new one. Only computer ids
/// that still have a character in the save guard's ledger are used.
/// </summary>
public sealed class IdentityStartupService : IHostedService
{
    private readonly SteamIdentityMapService _map;
    private readonly ILogger<IdentityStartupService> _log;

    public IdentityStartupService(SteamIdentityMapService map, ILogger<IdentityStartupService> log)
    {
        _map = map;
        _log = log;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        try
        {
            var files = new List<string>();
            var own = Path.Combine(AppContext.BaseDirectory, "logs");
            if (Directory.Exists(own)) files.AddRange(Directory.GetFiles(own, "hearth-*.log"));
            var launcherLog = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Logs", "hearthserver.log"));
            if (File.Exists(launcherLog)) files.Add(launcherLog);
            var ledger = Path.Combine(AppContext.BaseDirectory, "data", "player-records");
            var existed = File.Exists(_map.MapPath);
            var seeded = _map.SeedOnce(files, id => SteamIdentityMapService.LedgerHasCharacter(ledger, id));
            if (!existed)
                _log.LogInformation("Identity: Steam map seeded with {Count} players from {Files} log files", seeded, files.Count);
            else
                _log.LogInformation("Identity: Steam map has {Count} players", _map.Count);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Identity: could not seed the Steam map (joins stay as they are)");
        }
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
