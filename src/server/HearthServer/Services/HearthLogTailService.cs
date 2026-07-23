using System.Text.RegularExpressions;
using System.Text;
using HearthServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Tails the Bellwright host's UE log file (<c>{GameUserDir}/bw-ue.log</c> on
/// current builds, with the older <c>{GameUserDir}/Saved/Logs/Bellwright.log</c>
/// path kept as a fallback),
/// filters for operator-meaningful categories, and re-emits each line
/// through Serilog with a <c>[Bellwright]</c> source prefix. Joins, leaves, chat,
/// errors, save events, map travels — all show up interleaved with
/// HearthServer's own log stream.
///
/// Also looks for the Bellwright build banner on the first pass and registers it
/// with <see cref="HearthVersionInfo"/> so A2S responses can publish it.
/// </summary>
public sealed class HearthLogTailService : BackgroundService
{
    private static readonly Regex BuildRegex = new(
        @"LogInit:\s+Build:\s+(?<build>[A-Za-z0-9\-_.]+)",
        RegexOptions.Compiled);

    private static readonly Regex CategoryRegex = new(
        @"^\[[\d.\-: ]+\]\[\s*\d+\]\s*(?<cat>Log[A-Za-z]+):",
        RegexOptions.Compiled);

    // Bellwright log categories worth surfacing on the operator console.
    // Skip FMOD, RHI, Slate, ShaderCompiler, PakFile, IoDispatcher, etc.
    private static readonly HashSet<string> InterestingCategories = new(StringComparer.Ordinal)
    {
        "LogNet",
        "LogSaveSystem",
        "LogChat",
        "LogWorld",
        "LogGameplayMessage",
        "LogGlobalStatus",
        "LogOnline",
        "LogLoad",
        "LogExit",
    };

    private static readonly Regex JoinRegex   = new(
        @"(?:NotifyAcceptingConnection accepted from|Server accepting post-challenge connection from):\s*(?<addr>[^\s,]+)",
        RegexOptions.Compiled);
    private static readonly Regex LeaveRegex  = new(
        @"(?:UNetConnection::Close|UNetConnection::Tick: Connection TIMED OUT|UChannel::Close|UChannel::CleanUp).*RemoteAddr:\s*(?<addr>[^\s,]+)|UNetDriver::RemoveClientConnection - Removed address\s+(?<addr2>[^\s,]+)",
        RegexOptions.Compiled);
    private static readonly Regex TravelRegex = new(@"UEngine::Browse Started Browse:\s*""(?<url>[^""]+)""",    RegexOptions.Compiled);
    private static readonly Regex LoginNameRegex = new(
        @"LogNet:\s+Login request:\s+\?Name=(?<name>[^?\s]+)",
        RegexOptions.Compiled);
    private static readonly Regex LoginPlayerIdRegex = new(
        @"(?:\?PlayerId=(?<id>[^?\s]+)|\suserId:\s*(?<id>[^\s]+))",
        RegexOptions.Compiled);
    private static readonly Regex JoinSucceededRegex = new(
        @"LogNet:\s+Join succeeded:\s*(?<name>.+?)\s*$",
        RegexOptions.Compiled);
    private static readonly Regex GeneratedHexNameRegex = new(
        @"^[\w\-]+-[0-9A-Fa-f]{8,}$",
        RegexOptions.Compiled);
    private static readonly Regex GameplayJoinRegex = new(
        @"PlayerHasJoined.*INVTEXT\(""(?<name>[^""]+)""\)",
        RegexOptions.Compiled);
    private static readonly Regex GameplayLeaveRegex = new(
        @"PlayerHasLeft.*INVTEXT\(""(?<name>[^""]+)""\)",
        RegexOptions.Compiled);
    private static readonly Regex LogoutRegex = new(
        @"LogUWE:\s+Logout : Player .* is exiting",
        RegexOptions.Compiled);
    private static readonly Regex CredentialQueryRegex = new(
        @"(?<prefix>[?&](?:HearthKey|HearthAdminTicket)=)[^?&\s""]+",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private readonly ILogger<HearthLogTailService> _log;
    private readonly HearthServerOptions _opts;
    private readonly PipeServerState _state;
    // Address candidates from "accepted from" LogNet lines, stamped so stale
    // entries (e.g. a NAT-flapping zombie connection's old ports) can never be
    // paired with a later login — a stale pairing writes a wrong-address identity
    // row that bw_host can't match.
    private readonly Queue<(string Address, long SeenUnixMs)> _pendingAddresses = new();
    private static readonly TimeSpan PendingAddressTtl = TimeSpan.FromSeconds(60);
    private readonly Dictionary<string, PendingLogin> _pendingLogins = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _playerIdByAddress = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _playerNameByAddress = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, LoginIdentity> _loginIdentitiesByAddress = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _playerGate = new();
    private readonly string _loginIdentityCachePath;
    private long _position;
    private string? _lastBuildLogged;
    private bool _tailReadyForPlayerEvents;
    private string? _activeLogPath;
    private static readonly TimeSpan LoginIdentityCacheTtl = TimeSpan.FromMinutes(45);

    public HearthLogTailService(ILogger<HearthLogTailService> log, IOptions<HearthServerOptions> opts, PipeServerState state)
    {
        _log = log;
        _opts = opts.Value;
        _state = state;
        _loginIdentityCachePath = ResolveLoginIdentityCachePath(_opts.LoginIdentityCachePath);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_opts.GameUserDir))
        {
            _log.LogInformation("[Bellwright] log tail idle: GameUserDir not configured");
            return;
        }
        var logPaths = CandidateLogPaths(_opts.GameUserDir).ToArray();
        _log.LogInformation("[Bellwright] log tail watching {Paths}", string.Join(", ", logPaths));
        WriteLoginIdentityCache();

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var logPath = logPaths.FirstOrDefault(File.Exists);
                if (string.IsNullOrWhiteSpace(logPath))
                {
                    await Task.Delay(2000, ct).ConfigureAwait(false);
                    continue;
                }
                if (!string.Equals(_activeLogPath, logPath, StringComparison.OrdinalIgnoreCase))
                {
                    _activeLogPath = logPath;
                    _position = 0;
                    _tailReadyForPlayerEvents = false;
                    _log.LogInformation("[Bellwright] log tail active path {Path}", logPath);
                }
                if (!File.Exists(logPath))
                {
                    await Task.Delay(2000, ct).ConfigureAwait(false);
                    continue;
                }
                if (!_tailReadyForPlayerEvents)
                {
                    var catchUpEnd = new FileInfo(logPath).Length;
                    await CatchUpExistingLogAsync(logPath, catchUpEnd, ct).ConfigureAwait(false);
                    _position = catchUpEnd;
                    _tailReadyForPlayerEvents = true;
                    continue;
                }

                using var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (fs.Length < _position) _position = 0; // log rotated
                fs.Seek(_position, SeekOrigin.Begin);
                using var sr = new StreamReader(fs);
                string? line;
                while ((line = await sr.ReadLineAsync(ct).ConfigureAwait(false)) is not null)
                {
                    EmitLine(line, trackPlayerEvents: true);
                }
                _position = fs.Position;
            }
            catch (OperationCanceledException) { return; }
            catch (IOException) { /* log got rotated mid-read */ }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "[Bellwright] log tail loop error");
            }
            try { await Task.Delay(1500, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task CatchUpExistingLogAsync(string logPath, long endPosition, CancellationToken ct)
    {
        if (endPosition <= 0) return;
        if (endPosition > int.MaxValue)
        {
            _log.LogWarning("[Bellwright] existing log is too large for startup catch-up; starting live tail at EOF");
            return;
        }

        var bytes = new byte[(int)endPosition];
        var read = 0;
        await using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            while (read < bytes.Length)
            {
                var chunk = await fs.ReadAsync(bytes.AsMemory(read, bytes.Length - read), ct).ConfigureAwait(false);
                if (chunk <= 0) break;
                read += chunk;
            }
        }

        using var sr = new StringReader(Encoding.UTF8.GetString(bytes, 0, read));
        while (await sr.ReadLineAsync(ct).ConfigureAwait(false) is { } line)
        {
            EmitLine(line, trackPlayerEvents: false);
        }
    }

    private void EmitLine(string line, bool trackPlayerEvents)
    {
        if (string.IsNullOrEmpty(line)) return;

        // Existing logs can survive game updates, so keep the newest build
        // banner seen during the initial catch-up pass instead of pinning the
        // first historical one.
        var m = BuildRegex.Match(line);
        if (m.Success)
        {
            var build = m.Groups["build"].Value;
            HearthVersionInfo.SetHearthBuild(build);
            if (!string.Equals(_lastBuildLogged, build, StringComparison.Ordinal))
            {
                _log.LogInformation("[Bellwright] build detected: {Build}", build);
                _lastBuildLogged = build;
            }
        }

        var catMatch = CategoryRegex.Match(line);
        var cat = catMatch.Success ? catMatch.Groups["cat"].Value : null;
        var isInteresting = cat is not null && InterestingCategories.Contains(cat);
        if (!isInteresting) return;

        // Promote join / leave / travel to dedicated highlight messages.
        if (TryExtractAcceptedAddress(line, out var joinAddress))
        {
            var addr = joinAddress;
            if (trackPlayerEvents) TrackAcceptedAddress(addr);
            _log.LogInformation("[Bellwright] player connection accepted from {Addr}", addr);
            return;
        }
        var loginMatch = LoginNameRegex.Match(line);
        if (trackPlayerEvents && loginMatch.Success)
        {
            TrackLoginRequest(loginMatch.Groups["name"].Value, ExtractLoginPlayerId(line));
        }
        var joinSucceededMatch = JoinSucceededRegex.Match(line);
        if (joinSucceededMatch.Success)
        {
            if (trackPlayerEvents) TrackPlayerJoined(joinSucceededMatch.Groups["name"].Value);
            _log.LogInformation("[Bellwright] player joined: {Name}", joinSucceededMatch.Groups["name"].Value);
            return;
        }
        var gameplayJoinMatch = GameplayJoinRegex.Match(line);
        if (trackPlayerEvents && gameplayJoinMatch.Success)
        {
            TrackPlayerJoined(gameplayJoinMatch.Groups["name"].Value);
        }
        var gameplayLeaveMatch = GameplayLeaveRegex.Match(line);
        if (trackPlayerEvents && gameplayLeaveMatch.Success)
        {
            var name = gameplayLeaveMatch.Groups["name"].Value;
            TrackPlayerLeftByDisplayName(name);
            _log.LogInformation("[Bellwright] player left: {Name}", name);
            return;
        }
        if (TryExtractLeaveAddress(line, out var leaveAddress))
        {
            var addr = leaveAddress;
            if (trackPlayerEvents) TrackPlayerLeftByAddress(addr);
            _log.LogInformation("[Bellwright] connection closed for {Addr}", addr);
            return;
        }
        if (trackPlayerEvents && LogoutRegex.IsMatch(line))
        {
            _log.LogInformation("[Bellwright] player logout detected");
            return;
        }
        var travelMatch = TravelRegex.Match(line);
        if (travelMatch.Success)
        {
            _log.LogInformation(
                "[Bellwright] travel -> {Url}",
                RedactCredentialQueryValues(travelMatch.Groups["url"].Value));
            return;
        }

        // Default: pass through with [Bellwright] prefix and category as info.
        var safeLine = RedactCredentialQueryValues(line);
        if (safeLine.Contains("Error", StringComparison.OrdinalIgnoreCase))
            _log.LogError("[Bellwright] {Line}", safeLine);
        else if (safeLine.Contains("Warning", StringComparison.OrdinalIgnoreCase))
            _log.LogWarning("[Bellwright] {Line}", safeLine);
        else
            _log.LogInformation("[Bellwright] {Line}", safeLine);
    }

    private void TrackAcceptedAddress(string address)
    {
        if (string.IsNullOrWhiteSpace(address)) return;
        lock (_playerGate)
        {
            if (!_pendingAddresses.Any(p => string.Equals(p.Address, address, StringComparison.OrdinalIgnoreCase)))
                _pendingAddresses.Enqueue((address, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
            while (_pendingAddresses.Count > 16) _pendingAddresses.Dequeue();
        }
    }

    private void TrackLoginRequest(string displayName, string playerId)
    {
        var loginName = CleanName(Uri.UnescapeDataString(displayName));
        if (loginName.Length == 0) return;
        if (IsUnrealObjectIdentity(loginName)) return;
        var visibleName = IsGeneratedPlayerName(loginName) ? "Player" : loginName;
        var id = NormalizeLoginId(playerId, loginName);
        string? address = null;
        lock (_playerGate)
        {
            var staleBefore = DateTimeOffset.UtcNow.Subtract(PendingAddressTtl).ToUnixTimeMilliseconds();
            while (_pendingAddresses.Count > 0 && _pendingAddresses.Peek().SeenUnixMs < staleBefore)
                _pendingAddresses.Dequeue();
            if (_pendingAddresses.Count > 0) address = _pendingAddresses.Dequeue().Address;
            _pendingLogins[loginName] = new PendingLogin(id, visibleName, address, loginName);
            if (!string.IsNullOrWhiteSpace(address)) _playerIdByAddress[address] = id;
            if (!string.IsNullOrWhiteSpace(address)) _playerNameByAddress[address] = visibleName;
            // Always land an identity row: bw_host's recency-claim fallback needs a
            // row even when no usable accept-address was captured for this login.
            var identityKey = !string.IsNullOrWhiteSpace(address) ? address : $"pending:{loginName}";
            UpsertLoginIdentityLocked(identityKey, id, loginName, visibleName);
        }
        _state.UpsertLogPlayer(id, visibleName);
    }

    private void TrackPlayerJoined(string displayName)
    {
        displayName = CleanName(Uri.UnescapeDataString(displayName));
        PendingLogin? pending = null;
        lock (_playerGate)
        {
            if (displayName.Length > 0 && _pendingLogins.TryGetValue(displayName, out pending))
                _pendingLogins.Remove(displayName);
            else if (_pendingLogins.Count == 1)
            {
                var first = _pendingLogins.First();
                pending = first.Value;
                _pendingLogins.Remove(first.Key);
            }
        }
        if (pending is null && (displayName.Length == 0 || IsGeneratedPlayerName(displayName))) return;
        var visibleName = pending?.DisplayName ?? displayName;
        if (displayName.Length > 0 && !IsGeneratedPlayerName(displayName))
            visibleName = displayName;
        var id = pending?.PlayerId ?? $"bw:{displayName}";
        if (!string.IsNullOrWhiteSpace(pending?.Address))
        {
            lock (_playerGate)
            {
                _playerIdByAddress[pending.Address] = id;
                _playerNameByAddress[pending.Address] = visibleName;
                UpsertLoginIdentityLocked(pending.Address, id, pending.LoginName, visibleName);
            }
        }
        _state.UpsertLogPlayer(id, visibleName);
    }

    private void TrackPlayerLeftByDisplayName(string displayName)
    {
        displayName = CleanName(displayName);
        if (displayName.Length == 0) return;
        lock (_playerGate)
        {
            foreach (var key in _pendingLogins
                         .Where(kv => string.Equals(kv.Value.DisplayName, displayName, StringComparison.OrdinalIgnoreCase))
                         .Select(kv => kv.Key)
                         .ToList())
            {
                _pendingLogins.Remove(key);
            }
            foreach (var addr in _playerNameByAddress
                         .Where(kv => string.Equals(kv.Value, displayName, StringComparison.OrdinalIgnoreCase))
                         .Select(kv => kv.Key)
                         .ToList())
            {
                _playerNameByAddress.Remove(addr);
                _playerIdByAddress.Remove(addr);
                _loginIdentitiesByAddress.Remove(addr);
            }
            WriteLoginIdentityCache();
        }
        _state.RemoveLogPlayerByDisplayName(displayName);
    }

    private void TrackPlayerLeftByAddress(string address)
    {
        if (string.IsNullOrWhiteSpace(address)) return;
        string? id = null;
        string? displayName = null;
        lock (_playerGate)
        {
            if (_playerIdByAddress.TryGetValue(address, out id))
                _playerIdByAddress.Remove(address);
            if (_playerNameByAddress.TryGetValue(address, out displayName))
                _playerNameByAddress.Remove(address);
            _loginIdentitiesByAddress.Remove(address);
            WriteLoginIdentityCache();
        }
        var removed = false;
        if (!string.IsNullOrWhiteSpace(id))
        {
            _state.RemoveLogPlayer(id);
            removed = true;
        }
        if (!string.IsNullOrWhiteSpace(displayName))
        {
            _state.RemoveLogPlayerByDisplayName(displayName);
            removed = true;
        }
        if (!removed)
            _state.ClearLogPlayersIfOnlyOne();
    }

    private static string CleanName(string value) => value.Trim().Trim('"');

    private static string ResolveLoginIdentityCachePath(string configuredPath)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath)) return configuredPath;
        return Path.Combine(AppContext.BaseDirectory, "login-identities.tsv");
    }

    private void UpsertLoginIdentityLocked(string address, string hearthUserId, string loginName, string displayName)
    {
        if (string.IsNullOrWhiteSpace(address)) return;
        var seed = NormalizeLoginSeedForCache(hearthUserId, loginName);
        if (seed.Length == 0) return;
        var uid = NormalizeLoginUidForCache(hearthUserId, seed);
        var visibleName = CleanName(displayName);
        if (visibleName.Length == 0 || IsGeneratedPlayerName(visibleName)) visibleName = "Player";

        _loginIdentitiesByAddress[address] = new LoginIdentity(
            address,
            uid,
            seed,
            visibleName,
            loginName,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        WriteLoginIdentityCache();
    }

    private void WriteLoginIdentityCache()
    {
        try
        {
            var staleBefore = DateTimeOffset.UtcNow.Subtract(LoginIdentityCacheTtl).ToUnixTimeMilliseconds();
            foreach (var address in _loginIdentitiesByAddress
                         .Where(kv => kv.Value.UpdatedUnixMs < staleBefore)
                         .Select(kv => kv.Key)
                         .ToList())
            {
                _loginIdentitiesByAddress.Remove(address);
            }

            var dir = Path.GetDirectoryName(_loginIdentityCachePath);
            if (!string.IsNullOrWhiteSpace(dir)) Directory.CreateDirectory(dir);

            if (_loginIdentitiesByAddress.Count == 0)
            {
                if (File.Exists(_loginIdentityCachePath)) File.Delete(_loginIdentityCachePath);
                return;
            }

            var lines = _loginIdentitiesByAddress.Values
                .OrderBy(identity => identity.Address, StringComparer.OrdinalIgnoreCase)
                .Select(identity => string.Join('\t',
                    identity.UpdatedUnixMs.ToString(),
                    EncodeIdentityField(identity.Address),
                    EncodeIdentityField(identity.HearthUserId),
                    EncodeIdentityField(identity.Seed),
                    EncodeIdentityField(identity.DisplayName),
                    EncodeIdentityField(identity.LoginName)));

            var tmp = _loginIdentityCachePath + ".tmp";
            File.WriteAllLines(tmp, lines, Encoding.UTF8);
            File.Move(tmp, _loginIdentityCachePath, overwrite: true);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "[Bellwright] failed to write login identity cache");
        }
    }

    private static string EncodeIdentityField(string value) => Uri.EscapeDataString(value ?? "");

    private static string NormalizeLoginSeedForCache(string hearthUserId, string loginName)
    {
        var id = hearthUserId.Trim();
        if (id.StartsWith("bw:", StringComparison.OrdinalIgnoreCase)) id = id[3..];
        if (id.Length == 0 || id.Contains("...", StringComparison.Ordinal) || IsUnrealObjectIdentity(id))
            id = loginName;
        if (id.All(char.IsDigit) && id.Length is >= 15 and <= 20)
            return "steam_" + id;
        return Regex.Replace(id.Trim(), @"[^\w\-]", "_");
    }

    private static string NormalizeLoginUidForCache(string hearthUserId, string seed)
    {
        var id = hearthUserId.Trim();
        if (seed.StartsWith("steam_", StringComparison.OrdinalIgnoreCase)) return seed;
        if (id.StartsWith("bw:", StringComparison.OrdinalIgnoreCase)) return "bw:" + seed;
        if (id.Length > 0 && !id.Contains("...", StringComparison.Ordinal) && !IsUnrealObjectIdentity(id))
            return seed;
        return "bw:" + seed;
    }

    internal static IReadOnlyList<string> CandidateLogPaths(string gameUserDir) =>
        new[]
        {
            Path.Combine(gameUserDir, "bw-ue.log"),
            Path.Combine(gameUserDir, "Saved", "Logs", "Bellwright.log"),
        };

    internal static string RedactCredentialQueryValues(string line) =>
        CredentialQueryRegex.Replace(line, "${prefix}<redacted>");

    internal static string ExtractLoginPlayerId(string line)
    {
        var id = "";
        foreach (Match match in LoginPlayerIdRegex.Matches(line))
        {
            var candidate = match.Groups["id"].Value.Trim();
            if (candidate.Length == 0) continue;
            id = candidate;
            if (!candidate.Contains("...", StringComparison.Ordinal)) break;
        }
        return id;
    }

    private static string NormalizeLoginId(string playerId, string loginName)
    {
        var id = playerId.Trim();
        if (id.Length == 0 || id.Contains("...", StringComparison.Ordinal) || IsUnrealObjectIdentity(id))
            id = $"bw:{loginName}";
        return id;
    }

    internal static bool TryExtractAcceptedAddress(string line, out string address)
    {
        address = string.Empty;
        var match = JoinRegex.Match(line);
        if (!match.Success) return false;
        address = match.Groups["addr"].Value.Trim();
        return address.Length > 0;
    }

    internal static bool TryExtractLeaveAddress(string line, out string address)
    {
        address = string.Empty;
        var match = LeaveRegex.Match(line);
        if (!match.Success) return false;
        address = (match.Groups["addr"].Success ? match.Groups["addr"].Value : match.Groups["addr2"].Value).Trim();
        return address.Length > 0;
    }

    private static bool IsGeneratedPlayerName(string value)
    {
        return IsUnrealObjectIdentity(value)
               || value.Equals("OfflineUser", StringComparison.OrdinalIgnoreCase)
               || value.Equals("Player", StringComparison.OrdinalIgnoreCase)
               || value.StartsWith("ns", StringComparison.OrdinalIgnoreCase)
               || value.StartsWith("WIN-", StringComparison.OrdinalIgnoreCase)
               || value.StartsWith("DESKTOP-", StringComparison.OrdinalIgnoreCase)
               || GeneratedHexNameRegex.IsMatch(value);
    }

    private static bool IsUnrealObjectIdentity(string value)
    {
        var trimmed = value.Trim();
        var colon = trimmed.IndexOf(':');
        if (colon <= 0) return false;
        var prefix = trimmed[..colon];
        return prefix.StartsWith("U", StringComparison.OrdinalIgnoreCase)
               || prefix.Contains("Object", StringComparison.OrdinalIgnoreCase)
               || prefix.Contains("Struct", StringComparison.OrdinalIgnoreCase)
               || prefix.Contains("Class", StringComparison.OrdinalIgnoreCase)
               || prefix.Contains("Function", StringComparison.OrdinalIgnoreCase)
               || prefix.Contains("Property", StringComparison.OrdinalIgnoreCase)
               || prefix.Contains("Package", StringComparison.OrdinalIgnoreCase);
    }

    private sealed record PendingLogin(string PlayerId, string DisplayName, string? Address, string LoginName);

    private sealed record LoginIdentity(
        string Address,
        string HearthUserId,
        string Seed,
        string DisplayName,
        string LoginName,
        long UpdatedUnixMs);
}
