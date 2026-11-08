using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace HearthServer.Tests;

// The HTTP door's wrong-signature limit, on the real service, from a real non-loopback address.
// The signed routes download and replace the world with a key derived from the RCON password, so
// they get the same limit as RCON, and the count is shared with RCON: five wrong signatures with a
// FRESH timestamp in ten minutes turn the address away (a stale timestamp is a clock problem, not a
// guess); a turned-away request is refused before its body is read; players' public routes and
// loopback stay open; the block is logged once.
[Collection("SourceGuard")]
public sealed class HttpLockoutTests : IDisposable
{
    private const string Password = "lockout-test-secret";
    private static readonly byte[] Key = SHA256.HashData(Encoding.UTF8.GetBytes(Password));
    private static readonly byte[] WrongKey = SHA256.HashData(Encoding.UTF8.GetBytes("not-the-password"));

    public HttpLockoutTests() => TestNet.ResetGuard();
    public void Dispose() => TestNet.ResetGuard();

    [Fact]
    public async Task Five_fresh_wrong_signatures_turn_the_address_away_before_any_body_is_read()
    {
        var own = TestNet.OwnAddress();
        var log = new ListLogger<HearthHttpService>();
        await using var h = await Harness.StartAsync(log);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var none = Array.Empty<byte>();

        // Stale timestamps with wrong signatures: a clock problem, never counted.
        for (var i = 0; i < 10; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 3600 - i, from: own, signKey: WrongKey))
                .Status.Should().Be(401);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now, from: own)).Status.Should().Be(200);

        // Five wrong signatures with fresh timestamps.
        for (var i = 0; i < 5; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 10 - i, from: own, signKey: WrongKey))
                .Status.Should().Be(401);

        // The address is turned away now, right signature or not, and uploads are refused unread.
        var refused = await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 1, from: own);
        refused.Status.Should().Be(429, "five fresh wrong signatures turn the address away for a minute");
        refused.RetryAfterSeconds.Should().BeInRange(1, 60);

        var tempBefore = Harness.UploadTempFiles();
        var zip = new byte[200_000];
        RandomNumberGenerator.Fill(zip);
        (await h.SignedAsync("POST", "/api/v1/snapshots", zip, sendSha: true, ts: now - 2, from: own)).Status.Should().Be(429);
        (await h.SignedAsync("POST", "/api/v1/chat/say", Encoding.UTF8.GetBytes("{\"msg\":\"hi\"}"), sendSha: false, ts: now - 3, from: own))
            .Status.Should().Be(429);
        Harness.UploadTempFiles().Should().BeEquivalentTo(tempBefore, "a turned-away upload is never read to disk");
        Directory.EnumerateFiles(h.SaveDir, "*.zip").Should().BeEmpty();

        // Players' public routes from that address, and the same request over loopback, still answer.
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        using var players = await http.GetAsync($"http://{own}:{h.Port}/api/v1/players");
        ((int)players.StatusCode).Should().Be(200);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 4)).Status.Should().Be(200, "loopback is never limited");

        // One block line at warning level, naming the address, the door and the length, nothing secret.
        var blocks = log.Entries.Where(e => e.Text.Contains("auth block")).ToList();
        blocks.Should().ContainSingle("one line per block, not one per wrong try");
        blocks[0].Level.Should().Be(LogLevel.Warning);
        blocks[0].Text.Should().Contain("door=http").And.Contain("address=" + own).And.Contain("blocked=60s");
        blocks[0].Text.Should().NotContain(Password).And.NotMatchRegex("[0-9a-f]{64}");
    }

    [Fact]
    public async Task Only_a_fresh_well_formed_wrong_signature_counts_as_a_guess()
    {
        var own = TestNet.OwnAddress();
        await using var h = await Harness.StartAsync();
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var none = Array.Empty<byte>();

        // Malformed signatures (not 64 hex characters): not a guess at the key.
        for (var i = 0; i < 6; i++)
        {
            var good = Harness.Sign(WrongKey, "GET", "/api/v1/info", now - 10 - i, Harness.Sha(none));
            (await h.RawSignedAsync("GET", "/api/v1/info", now - 10 - i, "zz" + good[2..], own)).Should().Be(401);
            (await h.RawSignedAsync("GET", "/api/v1/info", now - 10 - i, "abc", own)).Should().Be(401);
        }

        // A replay of a signature that was already used: whoever sent it first held the key.
        var used = now - 30;
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: used, from: own)).Status.Should().Be(200);
        for (var i = 0; i < 6; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: used, from: own)).Status.Should().Be(401);

        // A correctly signed declared hash whose body does not match it, on both upload paths.
        for (var i = 0; i < 6; i++)
        {
            var big = new byte[70_000];
            RandomNumberGenerator.Fill(big);
            var otherSha = Harness.Sha(new byte[] { (byte)i });
            (await h.SignedAsync("POST", "/api/v1/snapshots", big, sendSha: true, ts: now - 40 - i, from: own, declaredSha: otherSha))
                .Status.Should().Be(401);
            (await h.SignedAsync("POST", "/api/v1/chat/say", Encoding.UTF8.GetBytes("{\"msg\":\"x\"}"), sendSha: true, ts: now - 50 - i, from: own, declaredSha: otherSha))
                .Status.Should().Be(401);
        }

        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now, from: own))
            .Status.Should().Be(200, "none of those was a guess at the key");
    }

    [Fact]
    public async Task A_good_signature_clears_the_count()
    {
        var own = TestNet.OwnAddress();
        await using var h = await Harness.StartAsync();
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var none = Array.Empty<byte>();

        for (var i = 0; i < 4; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 10 - i, from: own, signKey: WrongKey)).Status.Should().Be(401);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now, from: own)).Status.Should().Be(200);
        for (var i = 0; i < 4; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 20 - i, from: own, signKey: WrongKey)).Status.Should().Be(401);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 1, from: own))
            .Status.Should().Be(200, "four wrong, one right, four wrong is never five in a row");
    }

    private sealed class Harness : IAsyncDisposable
    {
        private readonly string _root;
        private readonly HearthHttpService _service;
        private readonly CancellationTokenSource _cts;

        public int Port { get; }
        public string SaveDir { get; }

        private Harness(string root, HearthHttpService service, CancellationTokenSource cts, int port, string saveDir)
        {
            _root = root; _service = service; _cts = cts; Port = port; SaveDir = saveDir;
        }

        public static async Task<Harness> StartAsync(ILogger<HearthHttpService>? log = null)
        {
            var root = Path.Combine(Path.GetTempPath(), "hearth-http-lockout-tests", Guid.NewGuid().ToString("N"));
            var saveDir = Path.Combine(root, "saves");
            Directory.CreateDirectory(Path.Combine(root, "data"));
            Directory.CreateDirectory(saveDir);
            var port = FreePort();
            var opts = new HearthServerOptions
            {
                HttpPort = port,
                RconPassword = Password,
                HmacKeyPath = Path.Combine(root, "data", "hmac.key"),
                AdminJoinTicketPath = Path.Combine(root, "data", "tickets.tsv"),
                SaveDir = saveDir,
                GamePidFile = "",
            };
            var o = Options.Create(opts);
            var pipe = new PipeServerState(NullLogger<PipeServerState>.Instance);
            var saves = new SaveOrchestratorService(
                NullLogger<SaveOrchestratorService>.Instance, o, pipe,
                new HearthRestartCoordinator(NullLogger<HearthRestartCoordinator>.Instance, o),
                new SaveProtectionService(NullLogger<SaveProtectionService>.Instance, o));
            var service = new HearthHttpService(
                log ?? NullLogger<HearthHttpService>.Instance, o,
                new ConfigurationBuilder().Build(),
                saves, pipe, new InstanceIdentityProvider(o),
                new ChatService(NullLogger<ChatService>.Instance, new StaticMonitor(opts)),
                new AdminJoinTicketService(o, NullLogger<AdminJoinTicketService>.Instance));
            var cts = new CancellationTokenSource();
            await service.StartAsync(cts.Token);

            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            var until = DateTime.UtcNow.AddSeconds(10);
            while (true)
            {
                try
                {
                    using var r = await http.GetAsync($"http://127.0.0.1:{port}/api/v1/players");
                    if (r.StatusCode == HttpStatusCode.OK) break;
                }
                catch (HttpRequestException) { }
                if (DateTime.UtcNow > until) throw new InvalidOperationException("HTTP service did not come up");
                await Task.Delay(100);
            }
            return new Harness(root, service, cts, port, saveDir);
        }

        public async ValueTask DisposeAsync()
        {
            _cts.Cancel();
            try { await _service.StopAsync(CancellationToken.None); } catch { }
            _cts.Dispose();
            try { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); } catch { }
        }

        public static string Sha(byte[] body) => Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant();

        public static string Sign(byte[] key, string method, string path, long ts, string sha) =>
            HearthHttpService.ComputeSignature(key, method, path, ts, sha);

        public static string[] UploadTempFiles()
        {
            var dir = Path.Combine(Path.GetTempPath(), "hearth-uploads");
            return Directory.Exists(dir) ? Directory.GetFiles(dir) : Array.Empty<string>();
        }

        public async Task<(int Status, int RetryAfterSeconds)> SignedAsync(string method, string path, byte[] body, bool sendSha,
            long? ts = null, IPAddress? from = null, byte[]? signKey = null, string? declaredSha = null)
        {
            var t = ts ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var sha = declaredSha ?? Sha(body);
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            using var req = new HttpRequestMessage(new HttpMethod(method), $"http://{from ?? IPAddress.Loopback}:{Port}{path}");
            req.Headers.Add("X-Hearth-Timestamp", t.ToString());
            req.Headers.Add("X-Hearth-Signature", Sign(signKey ?? Key, method, path, t, sha));
            if (sendSha) req.Headers.Add(HearthHttpService.ContentShaHeader, sha);
            if (body.Length > 0) req.Content = new ByteArrayContent(body);
            using var resp = await http.SendAsync(req);
            var retry = resp.Headers.RetryAfter?.Delta is TimeSpan d ? (int)d.TotalSeconds : 0;
            return ((int)resp.StatusCode, retry);
        }

        public async Task<int> RawSignedAsync(string method, string path, long ts, string signature, IPAddress from)
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            using var req = new HttpRequestMessage(new HttpMethod(method), $"http://{from}:{Port}{path}");
            req.Headers.Add("X-Hearth-Timestamp", ts.ToString());
            req.Headers.TryAddWithoutValidation("X-Hearth-Signature", signature);
            using var resp = await http.SendAsync(req);
            return (int)resp.StatusCode;
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

    private sealed class StaticMonitor : IOptionsMonitor<HearthServerOptions>
    {
        public StaticMonitor(HearthServerOptions value) => CurrentValue = value;
        public HearthServerOptions CurrentValue { get; }
        public HearthServerOptions Get(string? name) => CurrentValue;
        public IDisposable? OnChange(Action<HearthServerOptions, string?> listener) => null;
    }
}
