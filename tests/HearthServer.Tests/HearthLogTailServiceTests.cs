using HearthServer.Services;
using HearthServer.Configuration;
using FluentAssertions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace HearthServer.Tests;

public class HearthLogTailServiceTests
{
    [Fact]
    public void CandidateLogPaths_prefers_current_bellwright_userdir_log()
    {
        var paths = HearthLogTailService.CandidateLogPaths(@"C:\Hearth\userdir");

        paths[0].Should().Be(@"C:\Hearth\userdir/bw-ue.log".Replace('/', Path.DirectorySeparatorChar));
        paths[1].Should().Be(@"C:\Hearth\userdir/Saved/Logs/Bellwright.log".Replace('/', Path.DirectorySeparatorChar));
    }

    [Theory]
    [InlineData("[2026.07.05-11.43.23:456][386]LogNet: Login request: ?Name=DESKTOP-6UOAG27-B2FB9B014B553C1441850E80D9E14755?HearthKey=secret userId: NULL:DESKT...14755 platform: NULL", "NULL:DESKT...14755")]
    [InlineData("[2026.07.06-15.00.00:000][274]LogNet: Login request: ?Name=steam_76561198000000002?PlayerId=76561198000000002?PlatformUserId=76561198000000002?PlatformProvider=STEAM?HearthDisplayName=Gunran userId: NULL:steam...0002 platform: NULL", "76561198000000002")]
    [InlineData("[2026.05.22-21.00.35:672][274]LogNet: Login request: ?Name=HumanGenome??PlayerId=76561197966093888_A4E6F67EAD6BCF60?PlatformUserId=76561197966093888?PlatformProvider=STEAM userId: NULL:RYZEN platform: NULL", "76561197966093888_A4E6F67EAD6BCF60")]
    public void ExtractLoginPlayerId_handles_current_login_lines(string line, string expected)
    {
        HearthLogTailService.ExtractLoginPlayerId(line).Should().Be(expected);
    }

    [Fact]
    public void RedactCredentialQueryValues_removes_join_password_and_admin_ticket()
    {
        var line = "Login ?Name=Player?HearthKey=join-secret?HearthAdminTicket="
            + new string('a', 64)
            + "?PlayerId=76561197971106764";

        var redacted = HearthLogTailService.RedactCredentialQueryValues(line);

        redacted.Should().Contain("?HearthKey=<redacted>");
        redacted.Should().Contain("?HearthAdminTicket=<redacted>");
        redacted.Should().Contain("?PlayerId=76561197971106764");
        redacted.Should().NotContain("join-secret");
        redacted.Should().NotContain(new string('a', 64));
    }

    [Theory]
    [InlineData("[2026.05.22-19.54.11:411][123]LogNet: NotifyAcceptingConnection accepted from: 1.2.3.4:5555", "1.2.3.4:5555")]
    [InlineData("[2026.05.22-19.54.11:411][123]LogNet: Server accepting post-challenge connection from: 1.2.3.4:5555", "1.2.3.4:5555")]
    public void TryExtractAcceptedAddress_handles_current_g2_join_lines(string line, string expected)
    {
        HearthLogTailService.TryExtractAcceptedAddress(line, out var address).Should().BeTrue();
        address.Should().Be(expected);
    }

    [Theory]
    [InlineData("[2026.05.22-20.00.12:003][321]LogNet: UChannel::Close: ChIndex == 0. Closing connection. RemoteAddr: 1.2.3.4:5555", "1.2.3.4:5555")]
    [InlineData("[2026.05.22-20.00.12:003][321]LogNet: UChannel::CleanUp: ChIndex == 0. Closing connection. RemoteAddr: 1.2.3.4:5555", "1.2.3.4:5555")]
    [InlineData("[2026.05.22-20.00.12:003][321]LogNet: UNetConnection::Tick: Connection TIMED OUT. RemoteAddr: 1.2.3.4:5555", "1.2.3.4:5555")]
    [InlineData("[2026.05.22-20.00.12:003][321]LogNet: UNetDriver::RemoveClientConnection - Removed address 1.2.3.4:5555", "1.2.3.4:5555")]
    public void TryExtractLeaveAddress_handles_current_g2_disconnect_lines(string line, string expected)
    {
        HearthLogTailService.TryExtractLeaveAddress(line, out var address).Should().BeTrue();
        address.Should().Be(expected);
    }

    [Fact]
    public async Task Tailer_ignores_existing_join_lines_then_counts_new_live_join()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-g2-tail-" + Guid.NewGuid().ToString("N"));
        var logDir = Path.Combine(root, "Saved", "Logs");
        Directory.CreateDirectory(logDir);
        var logPath = Path.Combine(logDir, "Bellwright.log");
        await File.WriteAllTextAsync(logPath, string.Join(Environment.NewLine, new[]
        {
            "[2026.05.22-20.35.23:038][679]LogNet: NotifyAcceptingConnection accepted from: 1.2.3.4:1111",
            "[2026.05.22-20.35.23:271][686]LogNet: Login request: ?Name=OldPlayer??PlayerId=76561197966093888_OLD?PlatformUserId=76561197966093888?PlatformProvider=STEAM userId: NULL:RYZEN platform: NULL",
            "[2026.05.22-20.35.24:094][710]LogNet: Join succeeded: OldPlayer",
            ""
        }));

        var state = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var service = new HearthLogTailService(
            NullLogger<HearthLogTailService>.Instance,
            Options.Create(new HearthServerOptions { GameUserDir = root }),
            state);

        await service.StartAsync(CancellationToken.None);
        try
        {
            await Task.Delay(250);
            state.EffectivePlayerCount.Should().Be(0);

            await File.AppendAllTextAsync(logPath, string.Join(Environment.NewLine, new[]
            {
                "[2026.05.22-21.00.35:371][265]LogNet: NotifyAcceptingConnection accepted from: 5.6.7.8:2222",
                "[2026.05.22-21.00.35:472][268]LogNet: Server accepting post-challenge connection from: 5.6.7.8:2222",
                "[2026.05.22-21.00.35:672][274]LogNet: Login request: ?Name=HumanGenome??PlayerId=76561197966093888_A4E6F67EAD6BCF60?PlatformUserId=76561197966093888?PlatformProvider=STEAM userId: NULL:RYZEN platform: NULL",
                "[2026.05.22-21.00.36:662][303]LogNet: Join succeeded: HumanGenome",
                ""
            }));

            await WaitUntilAsync(() => state.EffectivePlayerCount == 1, TimeSpan.FromSeconds(5));
            state.Players.Single().DisplayName.Should().Be("HumanGenome");
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Tailer_reads_current_bw_ue_log_and_counts_generated_login_name()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-bw-tail-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var logPath = Path.Combine(root, "bw-ue.log");
        var identityPath = Path.Combine(root, "login-identities.tsv");
        await File.WriteAllTextAsync(logPath, "");

        var state = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var service = new HearthLogTailService(
            NullLogger<HearthLogTailService>.Instance,
            Options.Create(new HearthServerOptions { GameUserDir = root, LoginIdentityCachePath = identityPath }),
            state);

        await service.StartAsync(CancellationToken.None);
        try
        {
            await Task.Delay(250);
            await File.AppendAllTextAsync(logPath, string.Join(Environment.NewLine, new[]
            {
                "[2026.07.05-11.43.23:000][386]LogNet: NotifyAcceptingConnection accepted from: 5.6.7.8:2222",
                "[2026.07.05-11.43.23:456][386]LogNet: Login request: ?Name=DESKTOP-6UOAG27-B2FB9B014B553C1441850E80D9E14755?HearthKey=secret userId: NULL:DESKT...14755 platform: NULL",
                "[2026.07.05-11.43.26:424][475]LogNet: Join succeeded: ",
                ""
            }));

            await WaitUntilAsync(() => state.EffectivePlayerCount == 1, TimeSpan.FromSeconds(5));
            var player = state.Players.Single();
            player.HearthUserId.Should().Be("bw:DESKTOP-6UOAG27-B2FB9B014B553C1441850E80D9E14755");
            player.DisplayName.Should().Be("Player");
            var cache = await ReadLoginIdentityCacheAsync(identityPath);
            cache.Address.Should().Be("5.6.7.8:2222");
            cache.HearthUserId.Should().Be("bw:DESKTOP-6UOAG27-B2FB9B014B553C1441850E80D9E14755");
            cache.Seed.Should().Be("DESKTOP-6UOAG27-B2FB9B014B553C1441850E80D9E14755");
            cache.DisplayName.Should().Be("Player");
            cache.LoginName.Should().Be("DESKTOP-6UOAG27-B2FB9B014B553C1441850E80D9E14755");
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Tailer_updates_identity_cache_with_real_join_name_after_generated_login()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-bw-tail-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var logPath = Path.Combine(root, "bw-ue.log");
        var identityPath = Path.Combine(root, "login-identities.tsv");
        await File.WriteAllTextAsync(logPath, "");

        var state = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var service = new HearthLogTailService(
            NullLogger<HearthLogTailService>.Instance,
            Options.Create(new HearthServerOptions { GameUserDir = root, LoginIdentityCachePath = identityPath }),
            state);

        await service.StartAsync(CancellationToken.None);
        try
        {
            await Task.Delay(250);
            await File.AppendAllTextAsync(logPath, string.Join(Environment.NewLine, new[]
            {
                "[2026.07.07-16.52.47:000][386]LogNet: NotifyAcceptingConnection accepted from: 9.8.7.6:3333",
                "[2026.07.07-16.52.47:231][386]LogNet: Login request: ?Name=Havlas-43076A5D46EDB90453951599838B94B8?HearthKey=secret userId: NULL:Havla...B94B8 platform: NULL",
                "[2026.07.07-16.54.28:942][475]LogNet: Join succeeded: George",
                ""
            }));

            await WaitUntilAsync(() => state.Players.SingleOrDefault()?.DisplayName == "George", TimeSpan.FromSeconds(5));
            var player = state.Players.Single();
            player.HearthUserId.Should().Be("bw:Havlas-43076A5D46EDB90453951599838B94B8");
            player.DisplayName.Should().Be("George");
            var cache = await ReadLoginIdentityCacheAsync(identityPath);
            cache.Address.Should().Be("9.8.7.6:3333");
            cache.HearthUserId.Should().Be("bw:Havlas-43076A5D46EDB90453951599838B94B8");
            cache.Seed.Should().Be("Havlas-43076A5D46EDB90453951599838B94B8");
            cache.DisplayName.Should().Be("George");
            cache.LoginName.Should().Be("Havlas-43076A5D46EDB90453951599838B94B8");
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Tailer_ignores_unreal_object_identity_names()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-bw-tail-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var logPath = Path.Combine(root, "bw-ue.log");
        await File.WriteAllTextAsync(logPath, "");

        var state = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var service = new HearthLogTailService(
            NullLogger<HearthLogTailService>.Instance,
            Options.Create(new HearthServerOptions { GameUserDir = root }),
            state);

        await service.StartAsync(CancellationToken.None);
        try
        {
            await Task.Delay(250);
            await File.AppendAllTextAsync(logPath, string.Join(Environment.NewLine, new[]
            {
                "[2026.07.06-00.39.29:000][386]LogNet: NotifyAcceptingConnection accepted from: 5.6.7.8:2222",
                "[2026.07.06-00.39.29:456][386]LogNet: Login request: ?Name=UScriptStruct%3A%20000002A3481E7238?HearthKey=secret userId: NULL:UScri...7238 platform: NULL",
                "[2026.07.06-00.39.31:424][475]LogNet: Join succeeded: UScriptStruct: 000002A3481E7238",
                ""
            }));

            await Task.Delay(500);
            state.EffectivePlayerCount.Should().Be(0);
            state.Players.Should().BeEmpty();
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (condition()) return;
            await Task.Delay(50);
        }

        condition().Should().BeTrue();
    }

    private static async Task<LoginIdentityCacheEntry> ReadLoginIdentityCacheAsync(string path)
    {
        await WaitUntilAsync(() => File.Exists(path), TimeSpan.FromSeconds(5));
        var line = (await File.ReadAllLinesAsync(path)).Single();
        var fields = line.Split('\t');
        fields.Should().HaveCount(6);
        return new LoginIdentityCacheEntry(
            fields[0],
            Uri.UnescapeDataString(fields[1]),
            Uri.UnescapeDataString(fields[2]),
            Uri.UnescapeDataString(fields[3]),
            Uri.UnescapeDataString(fields[4]),
            Uri.UnescapeDataString(fields[5]));
    }

    private sealed record LoginIdentityCacheEntry(
        string UpdatedUnixMs,
        string Address,
        string HearthUserId,
        string Seed,
        string DisplayName,
        string LoginName);
}
