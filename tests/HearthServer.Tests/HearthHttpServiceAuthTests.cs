using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace HearthServer.Tests;

// Runs the real HTTP service on a loopback port and talks to it the way a
// remote caller would: raw sockets for requests whose body never arrives, an
// HttpClient for everything else.
// Shares the upload temp folder with the lockout tests, so the two never run at the same time.
[Collection("SourceGuard")]
public sealed class HearthHttpServiceAuthTests : IAsyncLifetime
{
    private const string Password = "test-admin-password";
    private static readonly byte[] Key = SHA256.HashData(Encoding.UTF8.GetBytes(Password));

    private readonly string _root = Path.Combine(Path.GetTempPath(), "hearth-http-auth-tests", Guid.NewGuid().ToString("N"));
    private readonly int _port = FreePort();
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private HearthHttpService? _service;
    private CancellationTokenSource? _cts;

    public async Task InitializeAsync()
    {
        Directory.CreateDirectory(Path.Combine(_root, "data"));
        Directory.CreateDirectory(Path.Combine(_root, "saves"));
        var opts = new HearthServerOptions
        {
            HttpPort = _port,
            RconPassword = Password,
            HmacKeyPath = Path.Combine(_root, "data", "hmac.key"),
            AdminJoinTicketPath = Path.Combine(_root, "data", "tickets.tsv"),
            SaveDir = Path.Combine(_root, "saves"),
            GamePidFile = "",
        };
        var o = Options.Create(opts);
        var pipe = new ServerState(NullLogger<ServerState>.Instance);
        var saves = new SaveOrchestratorService(
            NullLogger<SaveOrchestratorService>.Instance, o, pipe,
            new HearthRestartCoordinator(NullLogger<HearthRestartCoordinator>.Instance, o),
            new SaveProtectionService(NullLogger<SaveProtectionService>.Instance, o));
        _service = new HearthHttpService(
            NullLogger<HearthHttpService>.Instance, o,
            new ConfigurationBuilder().Build(),
            saves, pipe, new InstanceIdentityProvider(o),
            new AdminJoinTicketService(o, NullLogger<AdminJoinTicketService>.Instance));
        _cts = new CancellationTokenSource();
        await _service.StartAsync(_cts.Token);

        var until = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            try
            {
                using var r = await _http.GetAsync(Url("/api/v1/players"));
                if (r.StatusCode == HttpStatusCode.OK) break;
            }
            catch (HttpRequestException) { }
            if (DateTime.UtcNow > until) throw new InvalidOperationException("HTTP service did not come up");
            await Task.Delay(100);
        }
    }

    public async Task DisposeAsync()
    {
        _cts?.Cancel();
        if (_service is not null)
        {
            try { await _service.StopAsync(CancellationToken.None); } catch { }
        }
        _http.Dispose();
        try { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); } catch { }
    }

    [Fact]
    public async Task ForgedLargeUploadIsRefusedBeforeTheBodyArrives()
    {
        var before = UploadTempFiles();
        var ts = Now();
        var status = await RawStatusAsync(
            "POST", "/api/v1/snapshots/import-restore",
            $"Content-Length: 50000000\r\nX-Hearth-Timestamp: {ts}\r\nX-Hearth-Signature: {new string('a', 64)}\r\n" +
            $"X-Hearth-Content-Sha256: {new string('b', 64)}\r\n",
            TimeSpan.FromSeconds(5));

        status.Should().Be(401);
        UploadTempFiles().Should().BeEquivalentTo(before);
    }

    [Fact]
    public async Task LargeUploadWithoutDeclaredHashIsRefusedBeforeTheBodyArrives()
    {
        var before = UploadTempFiles();
        var status = await RawStatusAsync(
            "POST", "/api/v1/snapshots",
            $"Content-Length: 50000000\r\nX-Hearth-Timestamp: {Now()}\r\nX-Hearth-Signature: {new string('a', 64)}\r\n",
            TimeSpan.FromSeconds(5));

        status.Should().Be(428);
        UploadTempFiles().Should().BeEquivalentTo(before);
    }

    [Fact]
    public async Task UnsignedUploadIsRefusedBeforeTheBodyArrives()
    {
        var status = await RawStatusAsync(
            "POST", "/api/v1/snapshots/import-restore", "Content-Length: 50000000\r\n", TimeSpan.FromSeconds(5));

        status.Should().Be(401);
    }

    [Fact]
    public async Task ChunkedSignedBodyIsRefused()
    {
        var status = await RawStatusAsync(
            "POST", "/api/v1/snapshots",
            $"Transfer-Encoding: chunked\r\nX-Hearth-Timestamp: {Now()}\r\nX-Hearth-Signature: {new string('a', 64)}\r\n",
            TimeSpan.FromSeconds(5));

        status.Should().Be(411);
    }

    [Fact]
    public async Task SignedLargeUploadWithMatchingHashIsStored()
    {
        var body = RandomBytes(200 * 1024);
        using var resp = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/snapshots", body, declareHash: true));

        resp.StatusCode.Should().Be(HttpStatusCode.OK);
        Directory.GetFiles(Path.Combine(_root, "saves"), "*.zip").Should().ContainSingle()
            .Which.Should().Match(p => new FileInfo(p).Length == body.Length);
    }

    [Fact]
    public async Task SignedLargeUploadWhoseBodyDiffersFromTheDeclaredHashIsRefusedAndCleanedUp()
    {
        var before = UploadTempFiles();
        var declared = RandomBytes(200 * 1024);
        var sent = (byte[])declared.Clone();
        sent[^1] ^= 0xFF;
        using var req = Signed(HttpMethod.Post, "/api/v1/snapshots", declared, declareHash: true);
        req.Content = new ByteArrayContent(sent);
        using var resp = await _http.SendAsync(req);

        resp.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        Directory.GetFiles(Path.Combine(_root, "saves"), "*.zip").Should().BeEmpty();
        UploadTempFiles().Should().BeEquivalentTo(before);
    }

    [Fact]
    public async Task SignedLargeUploadWithoutDeclaredHashIsRefused()
    {
        var body = RandomBytes(200 * 1024);
        using var resp = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/snapshots", body, declareHash: false));

        resp.StatusCode.Should().Be((HttpStatusCode)428);
        // The exact words the app's World window shows; plain, no dashes.
        (await resp.Content.ReadAsStringAsync()).Should()
            .Be("{\"error\":\"Update your Hearth app to upload worlds to this server.\"}");
    }

    [Fact]
    public async Task SmallSignedCallWithoutDeclaredHashStillWorks()
    {
        // What an app from before the declared-hash header sends: a small signed body, read and
        // parsed (the reply says the Steam id is not an admin here, so the body got through).
        var body = Encoding.UTF8.GetBytes("{\"steam_id\":\"76561197960265729\"}");
        using var resp = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/admin/join-ticket", body, declareHash: false));

        resp.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await resp.Content.ReadAsStringAsync()).Should().Contain("not a configured admin");
    }

    [Fact]
    public async Task ReplayedSignatureIsRefused()
    {
        var first = Signed(HttpMethod.Get, "/api/v1/info", Array.Empty<byte>(), declareHash: false);
        var again = new HttpRequestMessage(HttpMethod.Get, first.RequestUri);
        foreach (var h in first.Headers) again.Headers.TryAddWithoutValidation(h.Key, h.Value);

        using var r1 = await _http.SendAsync(first);
        using var r2 = await _http.SendAsync(again);

        r1.StatusCode.Should().Be(HttpStatusCode.OK);
        r2.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task ChatRoutesAreGone()
    {
        // say, announce and motd reached no player (removed in v0.1.100); their HTTP routes went too.
        var body = Encoding.UTF8.GetBytes("{\"msg\":\"hi\"}");
        using var unsignedRecent = await _http.GetAsync(Url("/api/v1/chat/recent"));
        using var signedRecent = await _http.SendAsync(Signed(HttpMethod.Get, "/api/v1/chat/recent", Array.Empty<byte>(), false));
        using var signedMotd = await _http.SendAsync(Signed(HttpMethod.Get, "/api/v1/chat/motd", Array.Empty<byte>(), false));
        using var signedSay = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/chat/say", body, false));
        using var signedSetMotd = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/chat/motd", body, false));

        unsignedRecent.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        signedRecent.StatusCode.Should().Be(HttpStatusCode.NotFound);
        signedMotd.StatusCode.Should().Be(HttpStatusCode.NotFound);
        signedSay.StatusCode.Should().Be(HttpStatusCode.NotFound);
        signedSetMotd.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task PlayerChatIngestIsGone()
    {
        var body = Encoding.UTF8.GetBytes("{\"sender\":\"Someone\",\"msg\":\"hi\"}");
        using var unsigned = await _http.PostAsync(Url("/api/v1/chat/player"), new ByteArrayContent(body));
        using var signed = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/chat/player", body, false));

        unsigned.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        signed.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task HealthComesFromTheGameProcessOnly()
    {
        // No pid file here, so no game process: 503 and ok=false. The plugin pipe fields are gone
        // (nothing ever connected to the pipe; removed in v0.1.100).
        using var resp = await _http.GetAsync(Url("/api/v1/health"));
        var body = await resp.Content.ReadAsStringAsync();

        resp.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        body.Should().Contain("\"ok\":false");
        body.Should().NotContain("plugin_connected");
        body.Should().NotContain("last_heartbeat_age_seconds");
    }

    [Fact]
    public void ServerQueryClaimsAPasswordOnlyForTheJoinPassword()
    {
        // The pipe plane's keys (ServerPassword, PipeName, PluginHeartbeatTimeoutSeconds) are gone; an old
        // appsettings.json that still carries them binds to nothing and never sets "password required".
        // Only the join password (or its legacy name HearthAuthPassword) does.
        HearthServerOptions Bind(Dictionary<string, string?> values)
        {
            var bound = new HearthServerOptions();
            new ConfigurationBuilder().AddInMemoryCollection(values).Build().GetSection("Hearth").Bind(bound);
            return bound;
        }
        SourceQueryHostedService Query(HearthServerOptions o) => new(
            NullLogger<SourceQueryHostedService>.Instance, Options.Create(o),
            new ServerState(NullLogger<ServerState>.Instance));

        var old = Query(Bind(new()
        {
            ["Hearth:ServerPassword"] = "native",
            ["Hearth:PipeName"] = "hearth-old",
            ["Hearth:PluginHeartbeatTimeoutSeconds"] = "60",
            ["Hearth:ServerName"] = "Lab",
        }));
        old.BuildInfo().PasswordRequired.Should().BeFalse();
        old.BuildInfo().Name.Should().Be("Lab");

        Query(Bind(new() { ["Hearth:JoinPassword"] = "x" })).BuildInfo().PasswordRequired.Should().BeTrue();
        Query(Bind(new() { ["Hearth:HearthAuthPassword"] = "x" })).BuildInfo().PasswordRequired.Should().BeTrue();
    }

    [Fact]
    public async Task MapRoutesAreGone()
    {
        // The server's own web map had no position source (removed in v0.1.100); the panel's
        // World Map does not use it. /map/ is no longer listened on at all (not probed here: what
        // an unregistered prefix answers is the HTTP stack's business, and on Linux the managed
        // listener's answer to it unsettled the next request on the same connection in CI).
        using var unsignedState = await _http.GetAsync(Url("/api/v1/map/state"));
        using var signedState = await _http.SendAsync(Signed(HttpMethod.Get, "/api/v1/map/state", Array.Empty<byte>(), false));

        unsignedState.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        signedState.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task PublicReadsStayAvailableWhileEverySignedSlotIsHeld()
    {
        // Callers that claim a small body and never send it hold the signed
        // slots until the read deadline. The public pool is separate.
        var held = new List<TcpClient>();
        try
        {
            for (int i = 0; i < HearthHttpService.SignedConcurrentRequests + 2; i++)
            {
                var c = new TcpClient();
                await c.ConnectAsync(IPAddress.Loopback, _port);
                var head = $"POST /api/v1/admin/join-ticket HTTP/1.1\r\nHost: 127.0.0.1:{_port}\r\nContent-Length: 1000\r\n" +
                           $"X-Hearth-Timestamp: {Now()}\r\nX-Hearth-Signature: {new string('c', 64)}\r\n\r\n";
                await c.GetStream().WriteAsync(Encoding.ASCII.GetBytes(head));
                held.Add(c);
            }
            await Task.Delay(500);

            using var players = await _http.GetAsync(Url("/api/v1/players"));
            players.StatusCode.Should().Be(HttpStatusCode.OK);
        }
        finally
        {
            foreach (var c in held) c.Dispose();
        }
    }

    [Theory]
    [InlineData("GET", "/api/v1/health", true)]
    [InlineData("GET", "/api/v1/players", true)]
    [InlineData("GET", "/api/v1/manifest", true)]
    [InlineData("GET", "/map/", false)]
    [InlineData("GET", "/api/v1/map/state", false)]
    [InlineData("GET", "/api/v1/chat/recent", false)]
    [InlineData("GET", "/api/v1/chat/motd", false)]
    [InlineData("POST", "/api/v1/chat/player", false)]
    [InlineData("POST", "/api/v1/health", false)]
    [InlineData("GET", "/api/v1/snapshots", false)]
    public void PublicPoolHoldsOnlyTheUnsignedReads(string method, string path, bool expected)
    {
        HearthHttpService.IsPublicRequest(method, path).Should().Be(expected);
    }

    // ---- helpers ----

    private Uri Url(string path) => new($"http://127.0.0.1:{_port}{path}");

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    private static byte[] RandomBytes(int n)
    {
        var b = new byte[n];
        Random.Shared.NextBytes(b);
        return b;
    }

    private HttpRequestMessage Signed(HttpMethod method, string path, byte[] body, bool declareHash)
    {
        var ts = Now();
        var sha = Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant();
        var req = new HttpRequestMessage(method, Url(path));
        req.Headers.Add("X-Hearth-Timestamp", ts.ToString());
        req.Headers.Add("X-Hearth-Signature", HearthHttpService.ComputeSignature(Key, method.Method, path, ts, sha));
        if (declareHash) req.Headers.Add(HearthHttpService.ContentShaHeader, sha);
        if (body.Length > 0) req.Content = new ByteArrayContent(body);
        return req;
    }

    private static string[] UploadTempFiles()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hearth-uploads");
        return Directory.Exists(dir) ? Directory.GetFiles(dir) : Array.Empty<string>();
    }

    // Sends only the request head (no body) and returns the status code the
    // server answers with, or -1 if it does not answer within the timeout.
    private async Task<int> RawStatusAsync(string method, string path, string extraHeaders, TimeSpan timeout)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, _port);
        var stream = client.GetStream();
        var head = $"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{_port}\r\n{extraHeaders}\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
        using var cts = new CancellationTokenSource(timeout);
        var buf = new byte[512];
        var sb = new StringBuilder();
        try
        {
            while (!sb.ToString().Contains("\r\n"))
            {
                int n = await stream.ReadAsync(buf, cts.Token);
                if (n <= 0) break;
                sb.Append(Encoding.ASCII.GetString(buf, 0, n));
            }
        }
        catch (OperationCanceledException)
        {
            return -1;
        }
        var line = sb.ToString().Split("\r\n")[0];
        var parts = line.Split(' ');
        return parts.Length >= 2 && int.TryParse(parts[1], out var code) ? code : -1;
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }
}
