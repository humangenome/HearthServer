using System.Reflection;
using System.Text;
using FluentAssertions;
using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Logging.Abstractions;

namespace HearthServer.Tests;

// The join password (Hearth:JoinPassword): the file HearthServer writes for the bw_ident host mod, the digest both
// sides share, the A2S flag, and that nothing stops the game any more when a password is set.
public sealed class JoinGateFileTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "hearth-joingate-tests", Guid.NewGuid().ToString("N"));

    public JoinGateFileTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private JoinGateFileService Service(HearthServerOptions opts) =>
        new(opts, NullLogger<JoinGateFileService>.Instance, Path.Combine(_root, "data"));

    [Theory]
    // Same three vectors as src/native/Hearth.Identity/tests/join_gate_test.cpp (Python hashlib computed them).
    [InlineData("correct horse battery", "ab166b6e03efd20c411f1d1206e9fcafea2780e8c89d80d7a55a416b8efa03f7")]
    [InlineData("  pässwörd €  ", "396f4a72f23a7b5979765c588e72f32c65d54f2a6dd41825a1879139f47c3335")]
    [InlineData("x", "c63f268171ab99eab496e56e28078a246e7bae0f8010fdd66d36a994e446fbbe")]
    public void Digest_matches_the_host_mod_vectors(string password, string expected) =>
        JoinGateFileService.Digest(password).Should().Be(expected);

    [Fact]
    public void No_password_writes_open()
    {
        var opts = new HearthServerOptions();
        JoinGateFileService.FileText(opts).Should().Be("open\n");
        JoinGateFileService.PasswordRequired(opts).Should().BeFalse();
        new HearthServerOptions { JoinPassword = " \t " }.Let(JoinGateFileService.PasswordRequired).Should().BeFalse();
    }

    [Fact]
    public void A_password_writes_its_digest_never_the_password()
    {
        var opts = new HearthServerOptions { JoinPassword = " correct horse battery\r\n" };
        var text = JoinGateFileService.FileText(opts);
        text.Should().Be("v1 ab166b6e03efd20c411f1d1206e9fcafea2780e8c89d80d7a55a416b8efa03f7\n");
        text.Should().NotContain("correct");
        JoinGateFileService.PasswordRequired(opts).Should().BeTrue();
    }

    [Fact]
    public void JoinPassword_wins_and_the_legacy_name_still_counts()
    {
        JoinGateFileService.EffectivePassword(new HearthServerOptions { JoinPassword = "new", HearthAuthPassword = "old" })
            .Should().Be("new");
        JoinGateFileService.EffectivePassword(new HearthServerOptions { HearthAuthPassword = " old " }).Should().Be("old");
        JoinGateFileService.EffectivePassword(new HearthServerOptions { ServerPassword = "native" })
            .Should().BeEmpty("the legacy native ServerPassword is never the join password");
    }

    [Fact]
    public async Task Start_writes_the_file_without_a_byte_order_mark_and_replaces_an_old_one()
    {
        var locked = Service(new HearthServerOptions { JoinPassword = "x" });
        await locked.StartAsync(CancellationToken.None);
        var bytes = File.ReadAllBytes(locked.FilePath);
        bytes.Take(3).Should().NotEqual(new byte[] { 0xEF, 0xBB, 0xBF });
        Encoding.UTF8.GetString(bytes).Should().Be("v1 c63f268171ab99eab496e56e28078a246e7bae0f8010fdd66d36a994e446fbbe\n");

        // the owner clears the password: the next start must say open, not leave the old digest behind
        var open = Service(new HearthServerOptions());
        await open.StartAsync(CancellationToken.None);
        File.ReadAllText(open.FilePath).Should().Be("open\n");
        File.Exists(open.FilePath + ".tmp").Should().BeFalse();
    }

    [Fact]
    public void The_watchdog_no_longer_stops_the_game_over_a_password()
    {
        const BindingFlags any = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
        typeof(HeartbeatWatchdogService).GetMethod("CheckHearthAuthLuaReady", any).Should().BeNull(
            "it stopped the game about 3 minutes after every start whenever a password was set");
        typeof(HeartbeatWatchdogService).GetMethod("ReadLuaStatus", any).Should().BeNull();
    }
}

internal static class JoinGateTestExtensions
{
    public static TResult Let<T, TResult>(this T value, Func<T, TResult> f) => f(value);
}
