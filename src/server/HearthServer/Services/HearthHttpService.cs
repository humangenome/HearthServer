using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HearthServer.Configuration;
using HearthServer.Static;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Authenticated HTTP API for launcher-side snapshot management. Listens on
/// <see cref="HearthServerOptions.HttpPort"/>, validates an HMAC-SHA256
/// signature against the per-instance HMAC key, then dispatches to the save
/// orchestrator.
///
/// Routes (all under <c>/api/v1</c>):
///   GET  /health, /players, /manifest  — public, no auth
///   GET  /info                         — instance + version
///   GET  /chat/recent, /chat/motd      — admin broadcast history (auth)
///   GET  /snapshots                    — list snapshots (auth)
///   GET  /snapshots/{id}/download      — stream zip (auth)
///   POST /snapshots                    — upload zip body, store as snapshot (auth)
///   POST /snapshots/{id}/restore       — restore previously-stored snapshot (auth)
///   POST /snapshots/import-restore     — upload + restore in one shot (auth)
///
/// Auth: client computes
///   signature = HMAC_SHA256(key, method + "\n" + path + "\n" + ts + "\n" + body_sha256_hex)
/// and sends headers:
///   X-Hearth-Timestamp: &lt;unix seconds&gt;
///   X-Hearth-Signature: &lt;hex&gt;
///   X-Hearth-Content-Sha256: &lt;body_sha256_hex&gt;  (required when the body is over 64 KB)
/// Server rejects timestamps older than 5 minutes (replay window).
///
/// The signature is checked from the headers before any body byte is read:
/// a body of up to 64 KB is read into memory (Content-Length required, short
/// deadline) and hashed; a larger body must declare its hash up front, the
/// signature and replay check run on that declared hash, and only then is the
/// body streamed to disk, where the streamed hash must match. Public routes,
/// signed routes and large uploads each have their own concurrency limit, so
/// signed traffic can never starve the public health and player reads.
/// </summary>
public sealed class HearthHttpService : BackgroundService
{
    private const int ReplayWindowSeconds = 300;
    internal const int PublicConcurrentRequests = 16;
    internal const int SignedConcurrentRequests = 8;
    internal const int UploadConcurrentRequests = 2;
    internal const int SmallBodyMaxBytes = 64 * 1024;
    internal static readonly TimeSpan SmallBodyReadTimeout = TimeSpan.FromSeconds(15);
    internal const string ContentShaHeader = "X-Hearth-Content-Sha256";
    // Shown by the app's World window when an upload is refused. An app from
    // before the content hash header shows its own fixed "Import failed." text
    // whatever the answer says; it updates itself on launch.
    internal const string UpdateAppMessage = "Update your Hearth app to upload worlds to this server.";
    internal const string UploadBusyMessage = "Another world upload is running on this server. Try again in a few minutes.";

    private readonly ILogger<HearthHttpService> _log;
    private readonly HearthServerOptions _opts;
    private readonly IConfiguration _config;
    private readonly SaveOrchestratorService _saves;
    private readonly PipeServerState _pipeState;
    private readonly InstanceIdentityProvider _identity;
    private readonly ChatService _chat;
    private readonly AdminJoinTicketService _adminJoinTickets;
    private readonly byte[] _authKey;
    private readonly SemaphoreSlim _publicLimiter = new(PublicConcurrentRequests, PublicConcurrentRequests);
    private readonly SemaphoreSlim _signedLimiter = new(SignedConcurrentRequests, SignedConcurrentRequests);
    private readonly SemaphoreSlim _uploadLimiter = new(UploadConcurrentRequests, UploadConcurrentRequests);
    // Sliding window of signatures we've already accepted, so a captured
    // valid request inside the 5-minute replay window can't be re-sent to
    // double-trigger a restore or pile up snapshots.
    private readonly Dictionary<string, long> _seenSignatures = new();
    private readonly object _seenSignaturesLock = new();
    private HttpListener? _listener;

    public HearthHttpService(
        ILogger<HearthHttpService> log,
        IOptions<HearthServerOptions> opts,
        IConfiguration config,
        SaveOrchestratorService saves,
        PipeServerState pipeState,
        InstanceIdentityProvider identity,
        ChatService chat,
        AdminJoinTicketService adminJoinTickets)
    {
        _log = log;
        _opts = opts.Value;
        _config = config;
        _saves = saves;
        _pipeState = pipeState;
        _identity = identity;
        _chat = chat;
        _adminJoinTickets = adminJoinTickets;
        // The HTTP API auth secret is SHA256(RconPassword). Same trust tier
        // as RCON — if the customer has set an RCON password, they already
        // expose admin control of the world. Deriving from RconPassword
        // means there's no second secret to manage. If RconPassword is
        // empty, the HTTP API will not start.
        _authKey = string.IsNullOrEmpty(_opts.RconPassword)
            ? Array.Empty<byte>()
            : SHA256.HashData(Encoding.UTF8.GetBytes(_opts.RconPassword));
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (_opts.HttpPort <= 0)
        {
            _log.LogInformation("HTTP API disabled (HttpPort <= 0)");
            return;
        }
        if (_authKey.Length == 0)
        {
            _log.LogWarning("HTTP API disabled: RconPassword is empty (set it to enable launcher snapshot APIs)");
            return;
        }

        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://+:{_opts.HttpPort}/api/v1/");
        _listener.Prefixes.Add($"http://+:{_opts.HttpPort}/map/");

        try
        {
            _listener.Start();
            _log.LogInformation("HTTP API bound to all interfaces on port {Port}", _opts.HttpPort);
        }
        catch (HttpListenerException ex) when (ex.ErrorCode == 5 /* access denied */)
        {
            // Wildcard bind requires either Administrator or a one-time
            // urlacl registration. Try once to add the urlacl ourselves
            // (will succeed if we happen to be elevated). If that fails,
            // fall back to localhost — but log a clear error so customers
            // know remote launcher transfers will fail until urlacl is
            // provisioned.
            _log.LogWarning(ex,
                "HttpListener bind +:{Port} denied. Attempting netsh urlacl auto-registration",
                _opts.HttpPort);
            TryRegisterUrlAcl(_opts.HttpPort);

            try
            {
                _listener = new HttpListener();
                _listener.Prefixes.Add($"http://+:{_opts.HttpPort}/api/v1/");
                _listener.Prefixes.Add($"http://+:{_opts.HttpPort}/map/");
                _listener.Start();
                _log.LogInformation("HTTP API bound to all interfaces on port {Port} after urlacl fix", _opts.HttpPort);
            }
            catch (Exception retryEx)
            {
                _log.LogError(retryEx,
                    "HTTP API DEGRADED: bound to LOCALHOST ONLY on port {Port}. " +
                    "Remote launcher world transfers WILL FAIL. " +
                    "Fix: run as Administrator once, or pre-register with " +
                    "'netsh http add urlacl url=http://+:{Port}/ user=Everyone'",
                    _opts.HttpPort, _opts.HttpPort);
                _listener = new HttpListener();
                _listener.Prefixes.Add($"http://localhost:{_opts.HttpPort}/api/v1/");
                _listener.Prefixes.Add($"http://127.0.0.1:{_opts.HttpPort}/api/v1/");
                _listener.Prefixes.Add($"http://localhost:{_opts.HttpPort}/map/");
                _listener.Prefixes.Add($"http://127.0.0.1:{_opts.HttpPort}/map/");
                try { _listener.Start(); }
                catch (Exception innerEx)
                {
                    _log.LogError(innerEx, "HttpListener could not bind even to localhost:{Port}; HTTP API disabled", _opts.HttpPort);
                    return;
                }
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "HttpListener failed to start on port {Port}; HTTP API disabled", _opts.HttpPort);
            return;
        }

        _log.LogInformation("HTTP API listening on {Prefixes}", string.Join(", ", _listener.Prefixes));

        // Outer loop: if the listener crashes for any reason other than
        // shutdown, log it and restart after a short backoff so a transient
        // OS-level error doesn't permanently disable the API.
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                while (!stoppingToken.IsCancellationRequested && _listener.IsListening)
                {
                    HttpListenerContext ctx;
                    try
                    {
                        var getCtx = _listener.GetContextAsync();
                        var done = await Task.WhenAny(getCtx, Task.Delay(Timeout.Infinite, stoppingToken)).ConfigureAwait(false);
                        if (done != getCtx) break;
                        ctx = await getCtx.ConfigureAwait(false);
                    }
                    catch (ObjectDisposedException) { break; }
                    catch (OperationCanceledException) { break; }

                    // Bounded concurrency, one pool per kind of caller: refuse new
                    // requests if too many are already in flight rather than
                    // spawning unbounded Task.Run instances. Public reads have
                    // their own pool so signed traffic cannot crowd them out.
                    var limiter = IsPublicRequest(
                        ctx.Request.HttpMethod.ToUpperInvariant(),
                        ctx.Request.Url?.AbsolutePath ?? "",
                        _opts.Map)
                        ? _publicLimiter
                        : _signedLimiter;
                    if (!await limiter.WaitAsync(0).ConfigureAwait(false))
                    {
                        try
                        {
                            ctx.Response.StatusCode = 503;
                            ctx.Response.Headers["Retry-After"] = "5";
                            ctx.Response.Close();
                        }
                        catch { }
                        continue;
                    }

                    _ = Task.Run(async () =>
                    {
                        try { await HandleRequestAsync(ctx, stoppingToken).ConfigureAwait(false); }
                        finally { limiter.Release(); }
                    }, stoppingToken);
                }
            }
            catch (HttpListenerException ex)
            {
                _log.LogWarning(ex, "HttpListener accept loop crashed; restarting in 5s");
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "HttpListener accept loop hit unexpected error; restarting in 5s");
            }

            if (stoppingToken.IsCancellationRequested) break;
            try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            try
            {
                if (!_listener.IsListening) _listener.Start();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "HttpListener restart failed; will retry");
            }
        }

        try { _listener?.Stop(); } catch { }
        _log.LogInformation("HTTP API stopped");
    }

    private async Task HandleRequestAsync(HttpListenerContext ctx, CancellationToken ct)
    {
        var req = ctx.Request;
        var res = ctx.Response;
        var path = req.Url?.AbsolutePath ?? "";
        var method = req.HttpMethod.ToUpperInvariant();
        var remote = req.RemoteEndPoint?.ToString() ?? "?";

        _log.LogDebug("HTTP request {Method} {Path} from {Remote}", method, path, remote);

        try
        {
            res.Headers["X-Hearth-Instance"] = _identity.InstanceId;

            // Public endpoints
            if (method == "GET" && path == "/api/v1/health")
            {
                var heartbeatTimeout = TimeSpan.FromSeconds(Math.Max(1, _opts.PluginHeartbeatTimeoutSeconds));
                var pluginOnline = _pipeState.HasFreshHeartbeat(heartbeatTimeout);
                // Server is "online" if the plugin is pinging OR the Bellwright process is
                // alive (lobby-parked servers are joinable even before the plugin pings).
                var gameProcessAlive = GameProcessProbe.IsAlive(_opts.GamePidFile);
                var online = pluginOnline || gameProcessAlive;
                int? heartbeatAgeSeconds = null;
                if (_pipeState.LastHeartbeatAt is DateTimeOffset lastHeartbeat)
                    heartbeatAgeSeconds = Math.Max(0, (int)(DateTimeOffset.UtcNow - lastHeartbeat).TotalSeconds);

                _log.LogDebug(
                    "/health decision: online={Online} (pluginOnline={Plugin}, gameProcessAlive={Process}, heartbeatAge={Age}s)",
                    online, pluginOnline, gameProcessAlive, heartbeatAgeSeconds);

                await WriteJsonAsync(res, online ? 200 : 503, new
                {
                    ok = online,
                    instance = _identity.InstanceId,
                    server_name = string.IsNullOrWhiteSpace(_opts.ServerName) ? $"Hearth - {_identity.InstanceId}" : _opts.ServerName.Trim(),
                    hearth_version = HearthVersionInfo.HearthVersion,
                    hearth_build = HearthVersionInfo.HearthBuild,
                    gameplay_port = _opts.GameplayPort,
                    query_port = _opts.QueryPort,
                    max_players = _opts.MaxPlayers,
                    player_count = _pipeState.EffectivePlayerCount,
                    plugin_connected = _pipeState.Connection is not null,
                    last_heartbeat_age_seconds = heartbeatAgeSeconds,
                });
                return;
            }

            if (method == "GET" && path == "/api/v1/players")
            {
                // Public — same info Source A2S exposes, just as JSON so
                // the launcher hero panel doesn't have to parse A2S to
                // show 'who is online'. No auth required.
                var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                var snap = _pipeState.Players;
                await WriteJsonAsync(res, 200, new
                {
                    instance = _identity.InstanceId,
                    count = snap.Count,
                    players = snap.Select(p => new
                    {
                        name = string.IsNullOrEmpty(p.DisplayName) ? p.HearthUserId : p.DisplayName,
                        connected_seconds = Math.Max(0, (nowMs - p.ConnectedAtUnixMs) / 1000),
                        ping_ms = p.PingMs > 0 ? p.PingMs : (int?)null,
                    }),
                });
                return;
            }

            if (method == "GET" && path == "/api/v1/manifest")
            {
                // Public — players need this before they have RconPassword,
                // so HMAC is intentionally not enforced. Integrity rests on
                // per-mod sha256 pins in the payload. Spec:
                // protocol/manifest-v1.md.
                //
                // Read the Mods section fresh from IConfiguration so a
                // hoster editing appsettings.json never needs a restart.
                // ASP.NET Core's default appsettings provider has
                // reloadOnChange=true so this picks up edits within seconds.
                var mods = _config.GetSection("Hearth:Mods").Get<ModsOptions>() ?? new ModsOptions();
                await WriteJsonAsync(res, 200, new
                {
                    manifest_version = 1,
                    instance = _identity.InstanceId,
                    server_name = string.IsNullOrWhiteSpace(_opts.ServerName) ? $"Hearth - {_identity.InstanceId}" : _opts.ServerName.Trim(),
                    hearth_version = HearthVersionInfo.HearthVersion,
                    generated_unix = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                    required = (mods.Required ?? new()).Select(SerializeEntry),
                    recommended = (mods.Recommended ?? new()).Select(SerializeEntry),
                    blocked = (mods.Blocked ?? new()).Select(b => new
                    {
                        id = b.Id ?? "",
                        reason = b.Reason ?? "",
                    }),
                });
                return;
            }

            // ----- Live web map (protocol/map-v1.md) -----
            //
            // HearthRoster Lua mod writes roster.json (player list +
            // positions) every 5s and on K2_PostLogin/Logout.
            // /api/v1/map/state projects that into the SPA's expected
            // shape. Public when MapOptions.Public=true (community
            // dashboards) or HMAC-authed (launcher / private use) —
            // fall-through to the authed handler at the bottom of this
            // method covers the private path. The /map/ SPA HTML is
            // always public; if the state endpoint refuses the SPA's
            // poll the page renders "map is private" rather than failing
            // silently.

            if (method == "GET" && (path == "/map/" || path == "/map" || path == "/map/index.html"))
            {
                if (!_opts.Map.Enabled)
                {
                    await WriteJsonAsync(res, 404, new { error = "map disabled" });
                    return;
                }
                var html = MapSpa.Render();
                var bytes = Encoding.UTF8.GetBytes(html);
                res.StatusCode = 200;
                res.ContentType = "text/html; charset=utf-8";
                res.Headers["Cache-Control"] = "no-store";
                res.ContentLength64 = bytes.Length;
                await res.OutputStream.WriteAsync(bytes, ct).ConfigureAwait(false);
                res.OutputStream.Close();
                return;
            }

            if (method == "GET" && path == "/api/v1/map/state" && _opts.Map.Enabled && _opts.Map.Public)
            {
                await ServeMapStateAsync(res, ct).ConfigureAwait(false);
                return;
            }

            if (method == "GET" && path == "/api/v1/map/state" && !_opts.Map.Enabled)
            {
                await WriteJsonAsync(res, 404, new { error = "map disabled" });
                return;
            }

            // Auth required for everything below. The signature is checked
            // from the headers before the body is read (see the class
            // summary); the body, if any, then lands in a temp file and the
            // resulting BufferedBody is passed through to the route handler.
            var auth = await AuthorizeAndReadBodyAsync(ctx, ct).ConfigureAwait(false);
            if (auth.Body is null)
            {
                if (auth.Status == 0) return; // connection already aborted
                await WriteJsonAsync(res, auth.Status, new { error = auth.Error });
                return;
            }
            var body = auth.Body;

            // ----- Chat plane reads (protocol/chat-v1.md) -----
            // Admin broadcast history and the MOTD. Signed like every other
            // admin read; nothing in the game or the app reads them unsigned.
            if (method == "GET" && path == "/api/v1/chat/recent")
            {
                body.Dispose();
                var sinceMs = ParseLongQuery(req.Url, "since", 0);
                var limit = (int)ParseLongQuery(req.Url, "limit", 100);
                var msgs = _chat.GetRecent(sinceMs, limit);
                await WriteJsonAsync(res, 200, new
                {
                    version = 1,
                    instance = _identity.InstanceId,
                    now_ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    messages = msgs,
                });
                return;
            }

            if (method == "GET" && path == "/api/v1/chat/motd")
            {
                body.Dispose();
                await WriteJsonAsync(res, 200, new
                {
                    instance = _identity.InstanceId,
                    msg = _chat.GetMotd(),
                });
                return;
            }

            if (method == "GET" && path == "/api/v1/info")
            {
                body.Dispose();
                await WriteJsonAsync(res, 200, new
                {
                    instance = _identity.InstanceId,
                    hearth_version = HearthVersionInfo.HearthVersion,
                    hearth_build = HearthVersionInfo.HearthBuild,
                    gameplay_port = _opts.GameplayPort,
                    query_port = _opts.QueryPort,
                    max_players = _opts.MaxPlayers,
                });
                return;
            }

            if (method == "POST" && path == "/api/v1/admin/join-ticket")
            {
                var ticketRequest = await ParseJsonBodyAsync<AdminJoinTicketRequest>(body, ct).ConfigureAwait(false);
                body.Dispose();
                if (ticketRequest is null
                    || !AdminJoinTicketService.IsValidSteam64(ticketRequest.SteamId))
                {
                    await WriteJsonAsync(res, 400, new { error = "valid steam_id required" });
                    return;
                }

                var ticket = _adminJoinTickets.Issue(
                    ticketRequest.SteamId,
                    req.RemoteEndPoint?.Address?.ToString());
                if (ticket is null)
                {
                    await WriteJsonAsync(res, 403, new { error = "steam_id is not a configured admin" });
                    return;
                }

                await WriteJsonAsync(res, 200, new
                {
                    token = ticket.Token,
                    expires_unix = ticket.ExpiresUnix,
                });
                return;
            }

            // Authed entry for /api/v1/map/state. If MapOptions.Public is
            // set the public block above returned early; this branch handles
            // launcher + dashboard clients that authenticate via HMAC.
            if (method == "GET" && path == "/api/v1/map/state")
            {
                body.Dispose();
                if (!_opts.Map.Enabled)
                {
                    await WriteJsonAsync(res, 404, new { error = "map disabled" });
                    return;
                }
                await ServeMapStateAsync(res, ct).ConfigureAwait(false);
                return;
            }

            if (method == "GET" && path == "/api/v1/snapshots")
            {
                body.Dispose();
                var list = _saves.ListSnapshots();
                await WriteJsonAsync(res, 200, new
                {
                    snapshots = list.Select(s => new
                    {
                        id = s.SnapshotId,
                        taken_unix = s.TakenUnix,
                        size_bytes = s.SizeBytes,
                        sha256 = s.Sha256Hex,
                        retention_days = s.RetentionDays,
                    }),
                });
                return;
            }

            if (method == "GET" && path.StartsWith("/api/v1/snapshots/") && path.EndsWith("/download"))
            {
                body.Dispose();
                var id = path["/api/v1/snapshots/".Length..^"/download".Length];
                var record = _saves.ListSnapshots(int.MaxValue).FirstOrDefault(s => s.SnapshotId == id);
                if (record is null || !File.Exists(record.FilePath))
                {
                    await WriteJsonAsync(res, 404, new { error = "snapshot not found" });
                    return;
                }
                res.StatusCode = 200;
                res.ContentType = "application/zip";
                res.Headers["X-Hearth-Sha256"] = record.Sha256Hex;
                res.Headers["Content-Disposition"] = $"attachment; filename=\"{id}.zip\"";
                res.ContentLength64 = record.SizeBytes;
                await using (var fs = File.OpenRead(record.FilePath))
                {
                    await fs.CopyToAsync(res.OutputStream, ct).ConfigureAwait(false);
                }
                res.OutputStream.Close();
                return;
            }

            if (method == "POST" && path == "/api/v1/snapshots")
            {
                if (body.SizeBytes == 0)
                {
                    body.Dispose();
                    await WriteJsonAsync(res, 400, new { error = "empty body" });
                    return;
                }
                // The body is already on disk as a temp file. Just rename
                // it into SaveDir under the canonical snapshot name.
                Directory.CreateDirectory(_opts.SaveDir);
                var snapshotId = $"upload-{DateTimeOffset.UtcNow:yyyyMMddTHHmmssZ}-{Guid.NewGuid():N}".Substring(0, 36);
                var finalPath = Path.Combine(_opts.SaveDir, $"{snapshotId}.zip");
                File.Move(body.TempPath, finalPath);
                body.MarkConsumed(); // disposal won't try to delete the moved file

                var record = new Hearth.Persistence.SnapshotRecord(
                    SnapshotId: snapshotId,
                    TakenUnix: DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                    FilePath: finalPath,
                    SizeBytes: new FileInfo(finalPath).Length,
                    Sha256Hex: body.Sha256Hex,
                    RetentionDays: 30);
                _saves.Database.RecordSnapshot(record);
                _saves.Database.Audit("http-api", "snapshot.upload", snapshotId,
                    $"{{\"bytes\":{record.SizeBytes}}}", record.TakenUnix);

                await WriteJsonAsync(res, 200, new
                {
                    snapshot = new
                    {
                        id = record.SnapshotId,
                        taken_unix = record.TakenUnix,
                        size_bytes = record.SizeBytes,
                        sha256 = record.Sha256Hex,
                    },
                });
                return;
            }

            if (method == "POST" && path.StartsWith("/api/v1/snapshots/") && path.EndsWith("/restore"))
            {
                body.Dispose();
                var id = path["/api/v1/snapshots/".Length..^"/restore".Length];
                var ok = await _saves.RestoreSnapshotAsync(id, "http-api", ct).ConfigureAwait(false);
                await WriteJsonAsync(res, ok ? 200 : 500, new { ok });
                return;
            }

            if (method == "POST" && path == "/api/v1/snapshots/import-restore")
            {
                if (body.SizeBytes == 0)
                {
                    body.Dispose();
                    await WriteJsonAsync(res, 400, new { error = "empty body" });
                    return;
                }
                var ok = await _saves.RestoreFromZipPathAsync(
                    body.TempPath, "http-api", "snapshot.import_restore", ct).ConfigureAwait(false);
                body.Dispose();
                await WriteJsonAsync(res, ok ? 200 : 500, new { ok });
                return;
            }

            // ----- Chat plane writes (protocol/chat-v1.md) -----
            if (method == "POST" && path == "/api/v1/chat/say")
            {
                var sayReq = await ParseJsonBodyAsync<ChatSayRequest>(body, ct).ConfigureAwait(false);
                body.Dispose();
                if (sayReq is null || string.IsNullOrWhiteSpace(sayReq.Msg))
                {
                    await WriteJsonAsync(res, 400, new { error = "msg required" });
                    return;
                }
                var entry = _chat.BroadcastFromServer(
                    sayReq.Msg, sayReq.Channel, sayReq.Color, sayReq.Sender);
                await WriteJsonAsync(res, 200, new { ok = true, ts = entry.Ts });
                return;
            }

            if (method == "POST" && path == "/api/v1/chat/motd")
            {
                var motdReq = await ParseJsonBodyAsync<MotdRequest>(body, ct).ConfigureAwait(false);
                body.Dispose();
                if (motdReq is null)
                {
                    await WriteJsonAsync(res, 400, new { error = "json body required" });
                    return;
                }
                var ok = _chat.SetMotd(motdReq.Msg ?? "");
                await WriteJsonAsync(res, ok ? 200 : 500, new { ok });
                return;
            }

            body.Dispose();
            await WriteJsonAsync(res, 404, new { error = "not found", method, path });
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "HTTP {Method} {Path} threw", method, path);
            try
            {
                await WriteJsonAsync(res, 500, new { error = ex.Message });
            }
            catch { }
        }
        finally
        {
            try { _log.LogDebug("HTTP response {Method} {Path} -> {Status}", method, path, res.StatusCode); }
            catch { }
            try { res.Close(); } catch { }
        }
    }

    /// <summary>
    /// Which accept-loop pool a request belongs to. Public = the reads that
    /// answer without a signature (and the map routes, which only ever answer
    /// "disabled" or public data). Everything else is signed.
    /// </summary>
    internal static bool IsPublicRequest(string method, string path, MapOptions map)
    {
        if (method != "GET") return false;
        if (path is "/api/v1/health" or "/api/v1/players" or "/api/v1/manifest") return true;
        if (path is "/map" or "/map/" or "/map/index.html") return true;
        if (path == "/api/v1/map/state") return !map.Enabled || map.Public;
        return false;
    }

    internal readonly record struct AuthOutcome(BufferedBody? Body, int Status, string Error)
    {
        public static AuthOutcome Fail(int status, string error) => new(null, status, error);
    }

    /// <summary>The HMAC-SHA256 signature over method, path, timestamp and body hash, lower hex.</summary>
    internal static string ComputeSignature(byte[] key, string method, string path, long ts, string bodySha256Hex)
    {
        var canonical = $"{method}\n{path}\n{ts}\n{bodySha256Hex}";
        return Convert.ToHexString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    }

    private static bool IsSha256Hex(string? s)
    {
        if (s is null || s.Length != 64) return false;
        foreach (var c in s)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    private bool SignatureMatches(string method, string path, long ts, string bodySha, string sigHeader)
    {
        var expected = ComputeSignature(_authKey, method, path, ts, bodySha);
        return CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(expected),
            Encoding.ASCII.GetBytes(sigHeader.ToLowerInvariant()));
    }

    /// <summary>
    /// Records an accepted signature; false if it was already used inside the
    /// replay window.
    /// </summary>
    private bool TryConsumeSignature(string sigHeader, long ts, long now)
    {
        var sigKey = sigHeader.ToLowerInvariant();
        lock (_seenSignaturesLock)
        {
            if (_seenSignatures.Count > 0)
            {
                var cutoff = now - ReplayWindowSeconds;
                var toRemove = _seenSignatures
                    .Where(kv => kv.Value < cutoff)
                    .Select(kv => kv.Key)
                    .ToList();
                foreach (var k in toRemove) _seenSignatures.Remove(k);
            }
            if (_seenSignatures.ContainsKey(sigKey)) return false;
            _seenSignatures[sigKey] = ts;
            return true;
        }
    }

    /// <summary>
    /// Checks the request's signature from its headers before reading the
    /// body, then reads the body into a temp file. A body of up to
    /// <see cref="SmallBodyMaxBytes"/> is read into memory under
    /// <see cref="SmallBodyReadTimeout"/>, hashed and verified, and only
    /// written to disk once the signature holds. A larger body must carry
    /// <see cref="ContentShaHeader"/>: the signature and the replay check run
    /// on that declared hash first, then the body streams to disk (at most
    /// <see cref="UploadConcurrentRequests"/> at once) and must hash to the
    /// declared value. Any temp file is deleted on every failure path.
    /// </summary>
    private async Task<AuthOutcome> AuthorizeAndReadBodyAsync(HttpListenerContext ctx, CancellationToken ct)
    {
        var req = ctx.Request;
        var tsHeader = req.Headers["X-Hearth-Timestamp"];
        var sigHeader = req.Headers["X-Hearth-Signature"];
        if (string.IsNullOrWhiteSpace(tsHeader) || string.IsNullOrWhiteSpace(sigHeader))
            return AuthOutcome.Fail(401, "unauthorized");
        if (!long.TryParse(tsHeader, out var ts)) return AuthOutcome.Fail(401, "unauthorized");

        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (Math.Abs(now - ts) > ReplayWindowSeconds) return AuthOutcome.Fail(401, "unauthorized");

        var path = req.Url?.AbsolutePath ?? "";
        var method = req.HttpMethod.ToUpperInvariant();

        // A body must say how long it is: no chunked uploads, so the size
        // decision below is made before the first byte.
        long length = 0;
        if (req.HasEntityBody)
        {
            if (req.ContentLength64 < 0) return AuthOutcome.Fail(411, "content length required");
            length = req.ContentLength64;
        }
        if (length > _opts.MaxUploadBytes) return AuthOutcome.Fail(413, "payload too large");

        var declaredRaw = req.Headers[ContentShaHeader];
        string? declared = null;
        if (!string.IsNullOrWhiteSpace(declaredRaw))
        {
            declared = declaredRaw.Trim().ToLowerInvariant();
            if (!IsSha256Hex(declared)) return AuthOutcome.Fail(401, "unauthorized");
        }

        if (length > SmallBodyMaxBytes)
        {
            if (declared is null) return AuthOutcome.Fail(428, UpdateAppMessage);
            if (!SignatureMatches(method, path, ts, declared, sigHeader) || !TryConsumeSignature(sigHeader, ts, now))
                return AuthOutcome.Fail(401, "unauthorized");
            if (!await _uploadLimiter.WaitAsync(0).ConfigureAwait(false))
                return AuthOutcome.Fail(503, UploadBusyMessage);
            try
            {
                BufferedBody streamed;
                try
                {
                    streamed = await StreamBodyToDiskAsync(req.InputStream, length, ct).ConfigureAwait(false);
                }
                catch (IncompleteBodyException)
                {
                    return AuthOutcome.Fail(400, "incomplete body");
                }
                if (!string.Equals(streamed.Sha256Hex, declared, StringComparison.Ordinal))
                {
                    streamed.Dispose();
                    return AuthOutcome.Fail(401, "unauthorized");
                }
                return new AuthOutcome(streamed, 200, "");
            }
            finally
            {
                _uploadLimiter.Release();
            }
        }

        // Small or empty body: read it whole, under a deadline, before deciding.
        byte[] bytes;
        if (length == 0)
        {
            bytes = Array.Empty<byte>();
        }
        else
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(SmallBodyReadTimeout);
            // HttpListener reads do not always observe a token, so a reader
            // that stalls past the deadline gets its connection closed.
            using var abortOnDeadline = deadline.Token.Register(() =>
            {
                try { ctx.Response.Abort(); } catch { }
            });
            try
            {
                bytes = await ReadExactAsync(req.InputStream, (int)length, deadline.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is OperationCanceledException or IncompleteBodyException or IOException or HttpListenerException or ObjectDisposedException)
            {
                if (deadline.IsCancellationRequested && !ct.IsCancellationRequested) return AuthOutcome.Fail(0, "");
                return AuthOutcome.Fail(400, "incomplete body");
            }
        }

        var sha = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        if (declared is not null && !string.Equals(declared, sha, StringComparison.Ordinal))
            return AuthOutcome.Fail(401, "unauthorized");
        if (!SignatureMatches(method, path, ts, sha, sigHeader) || !TryConsumeSignature(sigHeader, ts, now))
            return AuthOutcome.Fail(401, "unauthorized");

        return new AuthOutcome(await WriteTempBodyAsync(bytes, sha, ct).ConfigureAwait(false), 200, "");
    }

    private static string NewTempUploadPath()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "hearth-uploads");
        Directory.CreateDirectory(tempDir);
        return Path.Combine(tempDir, $"upload-{Guid.NewGuid():N}.bin");
    }

    private static async Task<byte[]> ReadExactAsync(Stream input, int length, CancellationToken ct)
    {
        var buffer = new byte[length];
        int total = 0;
        while (total < length)
        {
            int n = await input.ReadAsync(buffer.AsMemory(total, length - total), ct).ConfigureAwait(false);
            if (n <= 0) throw new IncompleteBodyException();
            total += n;
        }
        return buffer;
    }

    private static async Task<BufferedBody> WriteTempBodyAsync(byte[] bytes, string sha, CancellationToken ct)
    {
        var tempPath = NewTempUploadPath();
        try
        {
            await File.WriteAllBytesAsync(tempPath, bytes, ct).ConfigureAwait(false);
        }
        catch
        {
            try { File.Delete(tempPath); } catch { }
            throw;
        }
        return new BufferedBody(tempPath, sha, bytes.LongLength);
    }

    /// <summary>
    /// Stream exactly <paramref name="length"/> bytes into a temp file while
    /// hashing in 64 KB chunks. Never allocates a buffer the size of the body.
    /// The temp file is deleted if the body ends early or anything throws.
    /// </summary>
    private static async Task<BufferedBody> StreamBodyToDiskAsync(Stream input, long length, CancellationToken ct)
    {
        var tempPath = NewTempUploadPath();
        string sha;
        try
        {
            await using var fs = new FileStream(
                tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, useAsync: true);
            using var hasher = SHA256.Create();
            var buf = new byte[64 * 1024];
            long total = 0;
            while (total < length)
            {
                int want = (int)Math.Min(buf.Length, length - total);
                int n = await input.ReadAsync(buf.AsMemory(0, want), ct).ConfigureAwait(false);
                if (n <= 0) throw new IncompleteBodyException();
                total += n;
                hasher.TransformBlock(buf, 0, n, null, 0);
                await fs.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
            }
            hasher.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
            sha = Convert.ToHexString(hasher.Hash!).ToLowerInvariant();
        }
        catch
        {
            try { File.Delete(tempPath); } catch { }
            throw;
        }

        return new BufferedBody(tempPath, sha, length);
    }

    /// <summary>
    /// Holds a temp-file path + SHA256 of a streamed request body. Disposal
    /// deletes the temp file unless the route handler called
    /// <see cref="MarkConsumed"/> (route renamed it into permanent storage
    /// and owns it from that point on).
    /// </summary>
    internal sealed class BufferedBody : IDisposable
    {
        public string TempPath { get; }
        public string Sha256Hex { get; }
        public long SizeBytes { get; }
        private int _disposed;
        private int _consumed;

        public BufferedBody(string tempPath, string sha256Hex, long sizeBytes)
        {
            TempPath = tempPath;
            Sha256Hex = sha256Hex;
            SizeBytes = sizeBytes;
        }

        public void MarkConsumed() => Interlocked.Exchange(ref _consumed, 1);

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            if (_consumed != 0) return;
            try { if (File.Exists(TempPath)) File.Delete(TempPath); } catch { }
        }
    }

    private sealed class IncompleteBodyException : Exception { }

    /// <summary>
    /// Best-effort one-shot of
    /// <c>netsh http add urlacl url=http://+:{port}/ user=Everyone</c>.
    /// Succeeds when HearthServer happens to be running with elevation;
    /// silently no-ops otherwise. The caller still retries the bind and
    /// drops to localhost if this didn't help.
    /// </summary>
    private void TryRegisterUrlAcl(int port)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "netsh.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("http");
            psi.ArgumentList.Add("add");
            psi.ArgumentList.Add("urlacl");
            psi.ArgumentList.Add($"url=http://+:{port}/");
            psi.ArgumentList.Add("user=Everyone");
            using var p = System.Diagnostics.Process.Start(psi);
            if (p is null) return;
            if (!p.WaitForExit(3_000))
            {
                try { p.Kill(true); } catch { }
                return;
            }
            if (p.ExitCode == 0)
                _log.LogInformation("netsh urlacl registered for port {Port}", port);
            else
                _log.LogInformation("netsh urlacl returned {Code} for port {Port} (likely needs elevation)", p.ExitCode, port);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "netsh urlacl probe failed (non-fatal)");
        }
    }

    private static async Task WriteJsonAsync(HttpListenerResponse res, int status, object payload)
    {
        res.StatusCode = status;
        res.ContentType = "application/json; charset=utf-8";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        });
        res.ContentLength64 = bytes.Length;
        await res.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
    }

    /// <summary>
    /// Reads roster.json (written by the HearthRoster Lua mod every 5s,
    /// plus on K2_PostLogin/Logout) and projects it into the /api/v1/map/state
    /// response shape. Position fields (X/Y/Z, world.name) are populated by
    /// the same rescan that writes the player list, so map data is exactly
    /// as fresh as the roster snapshot.
    ///
    /// Why not a separate map-state.json: UE5 dedicated Bellwright with zero
    /// connected players ticks at near-zero rate, so a 1Hz Lua LoopAsync
    /// fires every 10+ min in idle state. Roster's 5s tick is the only
    /// scheduler in the mod chain that catches both join (via K2_PostLogin
    /// fast path) and movement (via active-engine tick when a player is
    /// in-world), so we co-locate position publishing with it.
    /// </summary>
    private async Task ServeMapStateAsync(HttpListenerResponse res, CancellationToken ct)
    {
        var rosterPath = Path.Combine(AppContext.BaseDirectory, "roster.json");
        long unixMs = 0;
        var stale = true;
        string worldName = "";
        var players = System.Array.Empty<object>();

        if (File.Exists(rosterPath))
        {
            try
            {
                var body = await File.ReadAllTextAsync(rosterPath, ct).ConfigureAwait(false);
                using var doc = JsonDocument.Parse(body);
                var root = doc.RootElement;
                if (root.TryGetProperty("unix_ms", out var ums) && ums.TryGetInt64(out var ms))
                    unixMs = ms;
                if (root.TryGetProperty("world", out var w) && w.ValueKind == JsonValueKind.Object
                    && w.TryGetProperty("name", out var wn))
                    worldName = wn.GetString() ?? "";
                if (root.TryGetProperty("players", out var pa) && pa.ValueKind == JsonValueKind.Array)
                {
                    var list = new List<object>(pa.GetArrayLength());
                    foreach (var p in pa.EnumerateArray())
                    {
                        list.Add(new
                        {
                            id    = p.TryGetProperty("HearthUserId", out var idEl) ? idEl.GetString() ?? "" : "",
                            name  = p.TryGetProperty("DisplayName",  out var nmEl) ? nmEl.GetString() ?? "" : "",
                            x     = p.TryGetProperty("X", out var xEl) && xEl.ValueKind == JsonValueKind.Number ? xEl.GetDouble() : 0,
                            y     = p.TryGetProperty("Y", out var yEl) && yEl.ValueKind == JsonValueKind.Number ? yEl.GetDouble() : 0,
                            z     = p.TryGetProperty("Z", out var zEl) && zEl.ValueKind == JsonValueKind.Number ? zEl.GetDouble() : 0,
                            biome = "",
                        });
                    }
                    players = list.ToArray();
                }
                var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                stale = (nowMs - unixMs) > _opts.Map.StaleAfterMs;
            }
            catch (Exception ex) when (ex is IOException or JsonException)
            {
                _log.LogDebug(ex, "roster.json read/parse failed for map state");
            }
        }

        await WriteJsonAsync(res, 200, new
        {
            instance = _identity.InstanceId,
            hearth_version = HearthVersionInfo.HearthVersion,
            server_name = string.IsNullOrWhiteSpace(_opts.ServerName)
                ? $"Hearth - {_identity.InstanceId}"
                : _opts.ServerName.Trim(),
            unix_ms = unixMs,
            stale,
            world = new { name = worldName },
            players,
        });
    }

    private static long ParseLongQuery(Uri? url, string key, long defaultValue)
    {
        if (url is null) return defaultValue;
        var q = url.Query;
        if (string.IsNullOrEmpty(q)) return defaultValue;
        if (q[0] == '?') q = q[1..];
        foreach (var pair in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            if (eq <= 0) continue;
            if (!pair.AsSpan(0, eq).SequenceEqual(key.AsSpan())) continue;
            var raw = Uri.UnescapeDataString(pair[(eq + 1)..]);
            if (long.TryParse(raw, out var v)) return v;
            return defaultValue;
        }
        return defaultValue;
    }

    private static async Task<T?> ParseJsonBodyAsync<T>(BufferedBody body, CancellationToken ct) where T : class
    {
        try
        {
            await using var fs = File.OpenRead(body.TempPath);
            return await JsonSerializer.DeserializeAsync<T>(fs, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
                PropertyNameCaseInsensitive = true,
            }, ct).ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }

    private sealed class ChatSayRequest
    {
        public string Msg { get; set; } = "";
        public string? Channel { get; set; }
        public string? Color { get; set; }
        public string? Sender { get; set; }
    }

    private sealed class MotdRequest
    {
        public string? Msg { get; set; }
    }

    private sealed class AdminJoinTicketRequest
    {
        public string SteamId { get; set; } = "";
    }

    private static object SerializeEntry(ModEntry e) => new
    {
        id = e.Id ?? "",
        name = e.Name ?? "",
        version = e.Version ?? "",
        url = e.Url ?? "",
        sha256 = string.IsNullOrEmpty(e.Sha256) ? null : e.Sha256,
        size_bytes = e.SizeBytes,
        install_root = e.InstallRoot ?? "",
        notes = string.IsNullOrEmpty(e.Notes) ? null : e.Notes,
    };
}
