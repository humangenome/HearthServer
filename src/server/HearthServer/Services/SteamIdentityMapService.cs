using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace HearthServer.Services;

/// <summary>
/// The Steam-to-first-computer map the HearthIdentity host mod reads: &lt;identity folder&gt;/steam-map.tsv, one
/// "steam64&lt;TAB&gt;computer id&lt;TAB&gt;unix seconds" line per player, first line wins and nothing is ever replaced.
/// Learned from joins that carried a valid identity token (so the Steam ID was checked by Steam); seeded once, the first
/// time the file does not exist, from the last 14 days of HearthServer logs, taking for each Steam ID the earliest
/// computer id that still has a character in the save guard's ledger (data/player-records). The ledger keeps no
/// creation order (the save guard rewrites each record through a temp file), so log order decides; every seeded line
/// is logged once (Steam ID tail, computer tail) so staff can spot and remove a wrong one.
/// </summary>
public sealed class SteamIdentityMapService
{
    private static readonly Regex LoginRegex = new(
        @"LogNet:\s+Login request:\s+(?<opts>\?\S+)", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private readonly ILogger<SteamIdentityMapService>? _log;
    private readonly object _gate = new();
    private readonly Dictionary<string, string> _map = new(StringComparer.Ordinal);

    public SteamIdentityMapService(IdentityTokenService tokens, ILogger<SteamIdentityMapService> log)
        : this(Path.Combine(tokens.Folder, "steam-map.tsv"), log)
    {
    }

    internal SteamIdentityMapService(string path, ILogger<SteamIdentityMapService>? log = null)
    {
        _log = log;
        MapPath = path;
        Load();
    }

    public string MapPath { get; }

    public int Count { get { lock (_gate) return _map.Count; } }

    public string? FirstComputerFor(string steam64)
    {
        lock (_gate) return _map.TryGetValue(steam64, out var id) ? id : null;
    }

    private void Load()
    {
        lock (_gate)
        {
            _map.Clear();
            if (!File.Exists(MapPath)) return;
            foreach (var raw in File.ReadAllLines(MapPath))
            {
                var line = raw.TrimEnd('\r');
                if (line.Length == 0 || line[0] == '#') continue;
                var cols = line.Split('\t');
                if (cols.Length < 2 || !IdentityTokenService.IsValidSteam64(cols[0]) || !IdentityTokenService.IsComputerId(cols[1])) continue;
                _map.TryAdd(cols[0], cols[1]);
            }
        }
    }

    /// <summary>Records the first computer for a Steam ID; false when it already had one (never replaced).</summary>
    public bool RecordFirst(string steam64, string computerId, long? nowUnix = null)
    {
        if (!IdentityTokenService.IsValidSteam64(steam64) || !IdentityTokenService.IsComputerId(computerId)) return false;
        lock (_gate)
        {
            if (_map.ContainsKey(steam64)) return false;
            _map[steam64] = computerId;
            var when = nowUnix ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            WriteLocked($"{steam64}\t{computerId}\t{when}");
        }
        _log?.LogInformation("Identity: first computer recorded for Steam ...{Tail}", steam64[^4..]);
        return true;
    }

    // Rewrite the whole file (temp + replace) so the host mod never reads half a line.
    private void WriteLocked(string? appended)
    {
        var existing = File.Exists(MapPath) ? File.ReadAllLines(MapPath).ToList() : new List<string> { "# steam64\tfirst computer id\tunix seconds" };
        if (appended is not null) existing.Add(appended);
        Directory.CreateDirectory(Path.GetDirectoryName(MapPath)!);
        var tmp = MapPath + ".tmp";
        File.WriteAllText(tmp, string.Join("\r\n", existing) + "\r\n");
        File.Move(tmp, MapPath, overwrite: true);
    }

    /// <summary>
    /// One-time seed when the map file does not exist yet. Returns the number of Steam IDs seeded (0 also writes the
    /// file, so the seed never runs twice).
    /// </summary>
    public int SeedOnce(IEnumerable<string> logFiles, Func<string, bool> hasCharacter)
    {
        lock (_gate)
        {
            if (File.Exists(MapPath)) return 0;
            var earliest = new Dictionary<string, (string Stamp, string Id)>(StringComparer.Ordinal);
            foreach (var file in logFiles)
            {
                IEnumerable<string> lines;
                try { lines = File.ReadLines(file); } catch (IOException) { continue; } catch (UnauthorizedAccessException) { continue; }
                foreach (var line in lines)
                {
                    var m = LoginRegex.Match(line);
                    if (!m.Success) continue;
                    var opts = m.Groups["opts"].Value;
                    var steam = OptionValue(opts, "PlayerId");
                    var id = OptionValue(opts, "Name");
                    if (!IdentityTokenService.IsValidSteam64(steam) || !IdentityTokenService.IsComputerId(id) || !hasCharacter(id)) continue;
                    var stamp = GameStamp(line) ?? Path.GetFileName(file) + line.Length.ToString("D8");
                    if (!earliest.TryGetValue(steam, out var cur) || string.CompareOrdinal(stamp, cur.Stamp) < 0)
                        earliest[steam] = (stamp, id!);
                }
            }
            var lines2 = new List<string> { $"# steam64\tfirst computer id\tunix seconds (seeded {DateTimeOffset.UtcNow:yyyy-MM-dd} from HearthServer logs)" };
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            foreach (var (steam, v) in earliest.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                _map[steam] = v.Id;
                lines2.Add($"{steam}\t{v.Id}\t{now}");
                // one line per seeded player so staff can see (and undo, by editing the file) a wrong one
                _log?.LogInformation("Identity: seeded Steam ...{SteamTail} -> computer {Computer}", steam[^4..], ShortComputer(v.Id));
            }
            Directory.CreateDirectory(Path.GetDirectoryName(MapPath)!);
            var tmp = MapPath + ".tmp";
            File.WriteAllText(tmp, string.Join("\r\n", lines2) + "\r\n");
            File.Move(tmp, MapPath, overwrite: true);
            return earliest.Count;
        }
    }

    /// <summary>"&lt;computer name&gt;-...&lt;last 4 of the machine id&gt;" for logs.</summary>
    internal static string ShortComputer(string id) => id.Length > 33 ? id[..^33] + "-..." + id[^4..] : id;

    /// <summary>True when the save guard's ledger holds a character for this computer id.</summary>
    public static bool LedgerHasCharacter(string ledgerDir, string computerId)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("NULL:" + computerId))).ToLowerInvariant();
        return File.Exists(Path.Combine(ledgerDir, hash + ".record"));
    }

    // "[2026.10.28-01.50.08:268]" from the game's own log line, which sorts in time order.
    private static string? GameStamp(string line)
    {
        var m = Regex.Match(line, @"\[(\d{4}\.\d\d\.\d\d-\d\d\.\d\d\.\d\d:\d{3})\]");
        return m.Success ? m.Groups[1].Value : null;
    }

    internal static string? OptionValue(string options, string key)
    {
        var needle = "?" + key + "=";
        var at = options.IndexOf(needle, StringComparison.Ordinal);
        if (at < 0) return null;
        var start = at + needle.Length;
        var end = options.IndexOf('?', start);
        var raw = end < 0 ? options[start..] : options[start..end];
        try { return Uri.UnescapeDataString(raw); } catch (UriFormatException) { return raw; }
    }
}
