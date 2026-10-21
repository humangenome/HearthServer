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
        var pipe = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var saves = new SaveOrchestratorService(
            NullLogger<SaveOrchestratorService>.Instance, o, pipe,
            new HearthRestartCoordinator(NullLogger<HearthRestartCoordinator>.Instance, o),
            new SaveProtectionService(NullLogger<SaveProtectionService>.Instance, o));
        _service = new HearthHttpService(
            NullLogger<HearthHttpService>.Instance, o,
            new ConfigurationBuilder().Build(),
            saves, pipe, new InstanceIdentityProvider(o),
            new ChatService(NullLogger<ChatService>.Instance, new StaticMonitor(opts)),
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
        // What an app from before the declared-hash header sends.
        var body = Encoding.UTF8.GetBytes("{\"msg\":\"server restarts in 10 minutes\"}");
        using var resp = await _http.SendAsync(Signed(HttpMethod.Post, "/api/v1/chat/say", body, declareHash: false));

        resp.StatusCode.Should().Be(HttpStatusCode.OK);
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
    public async Task ChatHistoryAndMotdNeedASignature()
    {
        using var unsignedRecent = await _http.GetAsync(Url("/api/v1/chat/recent"));
        using var unsignedMotd = await _http.GetAsync(Url("/api/v1/chat/motd"));
        using var signedRecent = await _http.SendAsync(Signed(HttpMethod.Get, "/api/v1/chat/recent", Array.Empty<byte>(), false));

        unsignedRecent.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        unsignedMotd.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        signedRecent.StatusCode.Should().Be(HttpStatusCode.OK);
        (await signedRecent.Content.ReadAsStringAsync()).Should().Contain("\"messages\"");
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
    public async Task PrivateMapStateNeedsASignature()
    {
        using var unsigned = await _http.GetAsync(Url("/api/v1/map/state"));
        using var signed = await _http.SendAsync(Signed(HttpMethod.Get, "/api/v1/map/state", Array.Empty<byte>(), false));

        unsigned.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        signed.StatusCode.Should().Be(HttpStatusCode.OK);
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
                var head = $"POST /api/v1/chat/say HTTP/1.1\r\nHost: 127.0.0.1:{_port}\r\nContent-Length: 1000\r\n" +
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
    [InlineData("GET", "/api/v1/health", true, false, true)]
    [InlineData("GET", "/api/v1/players", true, false, true)]
    [InlineData("GET", "/api/v1/manifest", true, false, true)]
    [InlineData("GET", "/map/", true, false, true)]
    [InlineData("GET", "/api/v1/map/state", true, false, false)]
    [InlineData("GET", "/api/v1/map/state", true, true, true)]
    [InlineData("GET", "/api/v1/map/state", false, false, true)]
    [InlineData("GET", "/api/v1/chat/recent", true, false, false)]
    [InlineData("GET", "/api/v1/chat/motd", true, false, false)]
    [InlineData("POST", "/api/v1/chat/player", true, false, false)]
    [InlineData("POST", "/api/v1/health", true, false, false)]
    [InlineData("GET", "/api/v1/snapshots", true, false, false)]
    public void PublicPoolHoldsOnlyTheUnsignedReads(string method, string path, bool mapEnabled, bool mapPublic, bool expected)
    {
        HearthHttpService.IsPublicRequest(method, path, new MapOptions { Enabled = mapEnabled, Public = mapPublic })
            .Should().Be(expected);
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

    private sealed class StaticMonitor : IOptionsMonitor<HearthServerOptions>
    {
        public StaticMonitor(HearthServerOptions value) => CurrentValue = value;
        public HearthServerOptions CurrentValue { get; }
        public HearthServerOptions Get(string? name) => CurrentValue;
        public IDisposable? OnChange(Action<HearthServerOptions, string?> listener) => null;
    }
}
