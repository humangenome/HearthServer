using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace HearthServer.Tests;

// Character follows the Steam account: the token HearthServer signs (and the HearthIdentity host mod checks), the
// Steam-to-first-computer map, its one-time seed, the log tail that teaches it, and the public token route.
public sealed class IdentityTests : IDisposable
{
    private static readonly byte[] Key = Encoding.ASCII.GetBytes("0123456789abcdef0123456789abcdef");
    private const string Player = "76561199000000201";
    private const string FirstPc = "FIRST-PC-0A1B2C3D4E5F60718293A4B5C6D7E8F9";
    private const string Laptop = "NEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A";
    private readonly string _root = Path.Combine(Path.GetTempPath(), "hearth-identity-tests", Guid.NewGuid().ToString("N"));

    public IdentityTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    [Fact]
    public void Token_matches_the_host_mod_vector()
    {
        // Same vector as src/native/Hearth.Identity/tests/identity_core_test.cpp (Python hmac computed it).
        IdentityTokenService.Sign(Key, "v1|76561199000000201|1793300300|00112233445566778899aabb").Should().Be(
            "76317c37363536313139393030303030303230317c313739333330303330307c303031313232333334343535363637373838393961616262"
            + ".ce495602dbc8d140c7766e8d5bc11f682cac14f701ec02cf34f55a1b6f158ea3");
    }

    [Fact]
    public void Issued_token_verifies_only_for_its_Steam_ID_and_lifetime()
    {
        var svc = new IdentityTokenService(Key, _root);
        var (token, expires) = svc.Issue(Player, nowUnix: 1_793_300_000);
        expires.Should().Be(1_793_300_600);
        svc.Verify(token, Player, 1_793_300_000).Should().BeTrue();
        svc.Verify(token, "76561199000000101", 1_793_300_000).Should().BeFalse("another Steam ID");
        svc.Verify(token, Player, 1_793_300_601).Should().BeFalse("expired");
        svc.Verify(token[..^2] + (token[^2..] == "00" ? "11" : "00"), Player, 1_793_300_000).Should().BeFalse("changed signature");
        new IdentityTokenService(Encoding.ASCII.GetBytes("another-key-another-key-another!"), _root)
            .Verify(token, Player, 1_793_300_000).Should().BeFalse("another server's key");
        var longLived = IdentityTokenService.Sign(Key, $"v1|{Player}|{1_793_300_000 + 7200}|00112233445566778899aabb");
        svc.Verify(longLived, Player, 1_793_300_000).Should().BeFalse("valid for hours");
        svc.Verify("zz.zz", Player).Should().BeFalse();
    }

    [Fact]
    public void Token_service_mints_and_keeps_its_key_file()
    {
        var opts = Options.Create(new HearthServerOptions { Identity = new IdentityOptions { Directory = _root } });
        var first = new IdentityTokenService(opts, NullLogger<IdentityTokenService>.Instance);
        var keyText = File.ReadAllText(Path.Combine(_root, "token.key"));
        keyText.Should().MatchRegex("^[0-9a-f]{64}$");
        var (token, _) = first.Issue(Player);
        new IdentityTokenService(opts, NullLogger<IdentityTokenService>.Instance).Verify(token, Player).Should().BeTrue("same key after a restart");
    }

    [Fact]
    public void Map_keeps_the_first_computer_and_never_replaces_it()
    {
        var path = Path.Combine(_root, "steam-map.tsv");
        var map = new SteamIdentityMapService(path);
        map.RecordFirst(Player, FirstPc, 100).Should().BeTrue();
        map.RecordFirst(Player, Laptop, 200).Should().BeFalse();
        map.RecordFirst("not-a-steam-id", Laptop).Should().BeFalse();
        map.RecordFirst("76561199000000101", "steam_x").Should().BeFalse();
        map.FirstComputerFor(Player).Should().Be(FirstPc);
        var lines = File.ReadAllLines(path);
        lines[0].Should().StartWith("#");
        lines.Should().Contain($"{Player}\t{FirstPc}\t100");
        new SteamIdentityMapService(path).FirstComputerFor(Player).Should().Be(FirstPc, "reloaded from the file");
    }

    [Fact]
    public void Seed_takes_the_earliest_computer_that_still_has_a_character_and_runs_once()
    {
        var log1 = Path.Combine(_root, "hearth-20261026.log");
        var log2 = Path.Combine(_root, "hearthserver.log");
        File.WriteAllLines(log1,
        [
            // compact JSON line, as HearthServer writes its own log
            "{\"@t\":\"2026-10-27T15:34:00Z\",\"@mt\":\"[Bellwright] [2026.10.27-15.34.00:100][1]LogNet: Login request: ?Name=" + FirstPc + "?PlayerId=" + Player + "?HearthDisplayName=Player userId: NULL:FIRST...\"}",
            "[18:50:08 INF] [Bellwright] [2026.10.28-00.08.00:000][2]LogNet: Login request: ?Name=" + Laptop + "?PlayerId=" + Player + "?HearthDisplayName=Player userId: NULL:NEW...",
        ]);
        File.WriteAllLines(log2,
        [
            "[18:50:08 INF] [Bellwright] [2026.10.20-10.00.00:000][3]LogNet: Login request: ?Name=OLD-PC-ABCDEFABCDEFABCDEFABCDEFABCDEFAB?PlayerId=" + Player + " userId: NULL:OLD...",
            "[18:50:08 INF] [Bellwright] [2026.10.21-10.00.00:000][3]LogNet: Login request: ?Name=" + Laptop + "?PlayerId=76561199000000101 userId: NULL:x",
        ]);
        // OLD-PC is earlier but its character is gone from the ledger, so the first PC wins.
        bool HasCharacter(string id) => id is FirstPc or Laptop;
        var map = new SteamIdentityMapService(Path.Combine(_root, "steam-map.tsv"));
        map.SeedOnce([log1, log2], HasCharacter).Should().Be(2);
        map.FirstComputerFor(Player).Should().Be(FirstPc);
        map.FirstComputerFor("76561199000000101").Should().Be(Laptop);
        map.SeedOnce([log1, log2], _ => true).Should().Be(0, "the seed never runs twice");
    }

    [Fact]
    public void Ledger_lookup_uses_the_save_guards_file_name()
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("NULL:" + FirstPc))).ToLowerInvariant();
        File.WriteAllText(Path.Combine(_root, hash + ".record"), "x");
        SteamIdentityMapService.LedgerHasCharacter(_root, FirstPc).Should().BeTrue();
        SteamIdentityMapService.LedgerHasCharacter(_root, Laptop).Should().BeFalse();
    }

    [Fact]
    public void Log_tail_learns_only_from_logins_with_a_valid_token_and_hides_the_token()
    {
        var tokens = new IdentityTokenService(Key, _root);
        var map = new SteamIdentityMapService(Path.Combine(_root, "steam-map.tsv"));
        var options = Options.Create(new HearthServerOptions
        {
            GameUserDir = _root,
            LoginIdentityCachePath = Path.Combine(_root, "login-identities.tsv"),
            AdminJoinTicketPath = Path.Combine(_root, "admin-tickets.tsv"),
        });
        var tail = new HearthLogTailService(NullLogger<HearthLogTailService>.Instance, options,
            new PipeServerState(NullLogger<PipeServerState>.Instance),
            new AdminJoinTicketService(options, NullLogger<AdminJoinTicketService>.Instance), tokens, map);
        string Line(string name, string steam, string? token) =>
            "[2026.10.29-18.00.00:000][1]LogNet: Login request: ?Name=" + name + "?PlayerId=" + steam
            + (token is null ? "" : "?HearthIdToken=" + token) + " userId: NULL:x platform: NULL";

        tail.RecordVerifiedComputer(Line(Laptop, Player, null)).Should().BeFalse("no token: the client's word only");
        var forged = IdentityTokenService.Sign(Encoding.ASCII.GetBytes("not-this-servers-key-not-this-se"), $"v1|{Player}|{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}|00112233445566778899aabb");
        tail.RecordVerifiedComputer(Line(Laptop, Player, forged)).Should().BeFalse("forged token");
        var (token, _) = tokens.Issue(Player);
        tail.RecordVerifiedComputer(Line(FirstPc, "76561199000000101", token)).Should().BeFalse("this player's token on someone else's Steam ID");
        tail.RecordVerifiedComputer(Line(FirstPc, Player, token)).Should().BeTrue();
        map.FirstComputerFor(Player).Should().Be(FirstPc);

        var redacted = HearthLogTailService.RedactCredentialQueryValues(Line(FirstPc, Player, token));
        redacted.Should().Contain("?HearthIdToken=<redacted>").And.NotContain(token);
    }

    [Fact]
    public async Task Token_route_issues_only_after_Steam_confirms_and_limits_each_address()
    {
        var port = FreePort();
        var verifier = new FakeVerifier();
        var tokens = new IdentityTokenService(Key, _root);
        var opts = new HearthServerOptions
        {
            HttpPort = port,
            RconPassword = "test-admin-password",
            HmacKeyPath = Path.Combine(_root, "hmac.key"),
            AdminJoinTicketPath = Path.Combine(_root, "tickets.tsv"),
            SaveDir = Path.Combine(_root, "saves"),
            GamePidFile = "",
            Identity = new IdentityOptions { MaxTokenRequestsPerMinute = 4 },
        };
        Directory.CreateDirectory(opts.SaveDir);
        var o = Options.Create(opts);
        var pipe = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var saves = new SaveOrchestratorService(NullLogger<SaveOrchestratorService>.Instance, o, pipe,
            new HearthRestartCoordinator(NullLogger<HearthRestartCoordinator>.Instance, o),
            new SaveProtectionService(NullLogger<SaveProtectionService>.Instance, o));
        var http = new HearthHttpService(NullLogger<HearthHttpService>.Instance, o, new ConfigurationBuilder().Build(),
            saves, pipe, new InstanceIdentityProvider(o),
            new ChatService(NullLogger<ChatService>.Instance, new StaticMonitor(opts)),
            new AdminJoinTicketService(o, NullLogger<AdminJoinTicketService>.Instance), tokens, verifier);
        using var cts = new CancellationTokenSource();
        await http.StartAsync(cts.Token);
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        try
        {
            async Task<HttpResponseMessage> Post(string json)
            {
                for (var i = 0; ; i++)
                {
                    try
                    {
                        return await client.PostAsync($"http://127.0.0.1:{port}/api/v1/identity/token",
                            new StringContent(json, Encoding.UTF8, "application/json"));
                    }
                    catch (HttpRequestException) when (i < 50) { await Task.Delay(100); }
                }
            }

            verifier.Next = new SteamTicketResult(SteamTicketOutcome.Ok, "Steam: OK");
            using (var ok = await Post($"{{\"steam_id\":\"{Player}\",\"ticket\":\"{new string('a', 64)}\"}}"))
            {
                ok.StatusCode.Should().Be(HttpStatusCode.OK);
                using var doc = JsonDocument.Parse(await ok.Content.ReadAsStringAsync());
                tokens.Verify(doc.RootElement.GetProperty("token").GetString(), Player).Should().BeTrue();
                verifier.LastSteamId.Should().Be(Player);
                verifier.LastTicket.Should().HaveCount(32);
            }

            verifier.Next = new SteamTicketResult(SteamTicketOutcome.Refused, "Steam: AuthTicketInvalid");
            using (var refused = await Post($"{{\"steam_id\":\"{Player}\",\"ticket\":\"{new string('b', 64)}\"}}"))
            {
                refused.StatusCode.Should().Be(HttpStatusCode.Forbidden);
                (await refused.Content.ReadAsStringAsync()).Should().NotContain("token\"");
            }

            using (var bad = await Post("{\"steam_id\":\"123\",\"ticket\":\"zz\"}"))
                bad.StatusCode.Should().Be(HttpStatusCode.BadRequest);

            verifier.Next = new SteamTicketResult(SteamTicketOutcome.Unavailable, "no answer");
            using (var down = await Post($"{{\"steam_id\":\"{Player}\",\"ticket\":\"{new string('c', 64)}\"}}"))
                down.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);

            using (var limited = await Post($"{{\"steam_id\":\"{Player}\",\"ticket\":\"{new string('d', 64)}\"}}"))
                limited.StatusCode.Should().Be((HttpStatusCode)429, "the fifth request in a minute from one address");
        }
        finally
        {
            cts.Cancel();
            await http.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task With_no_steam_library_the_check_says_unavailable_so_the_join_goes_on_as_before()
    {
        var missing = Path.Combine(Path.GetTempPath(), "hearth-no-steam-" + Guid.NewGuid().ToString("N"), "steam-library.dll");
        var options = Options.Create(new HearthServerOptions { Identity = new IdentityOptions { SteamApiPath = missing } });
        var verifier = new SteamGameServerTicketVerifier(options, NullLogger<SteamGameServerTicketVerifier>.Instance);

        var result = await verifier.VerifyAsync(Player, new byte[32], CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
        result.Outcome.Should().Be(SteamTicketOutcome.Unavailable);

        // and again once the checker has given up
        var later = await verifier.VerifyAsync(Player, new byte[32], CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
        later.Outcome.Should().Be(SteamTicketOutcome.Unavailable);
    }

    [Fact]
    public void No_hosting_panel_path_ships_in_the_public_server_code()
    {
        // The server side is public (scripts/carveout-paths.sh). A host's own install layout belongs in its settings
        // (Identity:SteamClientPath), never in the code: v0.1.97's first cut named the panel's shared Steam copy here.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Directory.Build.props"))) dir = dir.Parent;
        dir.Should().NotBeNull("the test runs inside the repository");
        var needle = string.Concat("ss", "panel");
        var roots = new[] { "src/server", "src/shared", "src/native", "src/tools", "dist/ue4ss-server", "dist/engine-ini" };
        var hits = new List<string>();
        foreach (var root in roots)
        {
            var path = Path.Combine(dir!.FullName, root);
            if (!Directory.Exists(path)) continue;
            foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                if (file.Contains(Path.DirectorySeparatorChar + "bin" + Path.DirectorySeparatorChar) || file.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar)) continue;
                var ext = Path.GetExtension(file).ToLowerInvariant();
                if (ext is not (".cs" or ".lua" or ".ps1" or ".json" or ".txt" or ".ini" or ".cfg" or ".cpp" or ".hpp" or ".h" or ".md" or ".toml" or ".rs")) continue;
                if (File.ReadAllText(file).Contains(needle, StringComparison.OrdinalIgnoreCase)) hits.Add(Path.GetRelativePath(dir.FullName, file));
            }
        }
        hits.Should().BeEmpty();
    }

    [Fact]
    public void The_configured_steam_client_is_used_first_and_a_missing_one_is_never_returned()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hearth-steamclient-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var there = Path.Combine(dir, "steamclient64.dll");
            File.WriteAllBytes(there, new byte[] { 1 });
            SteamGameServerTicketVerifier.FindSteamClient(there).Should().Be(there);
            SteamGameServerTicketVerifier.FindSteamClient(dir).Should().Be(there, "the setting may name the folder");
            SteamGameServerTicketVerifier.FindSteamClient(dir + Path.DirectorySeparatorChar).Should().Be(Path.Combine(dir + Path.DirectorySeparatorChar, "steamclient64.dll"));

            var gone = Path.Combine(dir, "gone", "steamclient64.dll");
            SteamGameServerTicketVerifier.FindSteamClient(gone).Should().NotBe(gone);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    private sealed class FakeVerifier : ISteamTicketVerifier
    {
        public SteamTicketResult Next { get; set; } = new(SteamTicketOutcome.Unavailable, "unset");
        public string? LastSteamId { get; private set; }
        public byte[]? LastTicket { get; private set; }

        public Task<SteamTicketResult> VerifyAsync(string steam64, byte[] ticket, CancellationToken ct)
        {
            LastSteamId = steam64;
            LastTicket = ticket;
            return Task.FromResult(Next);
        }
    }

    private sealed class StaticMonitor : IOptionsMonitor<HearthServerOptions>
    {
        public StaticMonitor(HearthServerOptions value) => CurrentValue = value;
        public HearthServerOptions CurrentValue { get; }
        public HearthServerOptions Get(string? name) => CurrentValue;
        public IDisposable? OnChange(Action<HearthServerOptions, string?> listener) => null;
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var p = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return p;
    }
}
