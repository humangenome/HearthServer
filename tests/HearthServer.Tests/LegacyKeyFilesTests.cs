using FluentAssertions;
using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Logging;

namespace HearthServer.Tests;

// The key files the removed plugin pipe left behind go at the next start (Security's term for the v0.1.100
// removal): exact names only, plain files only, never through a link, one log line.
public sealed class LegacyKeyFilesTests : IDisposable
{
    private const string Key = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
    private const string PluginConfig = "{\n  \"InstanceId\": \"bellwright-1\",\n  \"PipePath\": \"\\\\\\\\.\\\\pipe\\\\hearth\",\n  \"HmacKeyHex\": \"" + Key + "\",\n  \"ServerPassword\": \"\"\n}";

    private readonly string _root = Path.Combine(Path.GetTempPath(), "hearth-legacykey-tests", Guid.NewGuid().ToString("N"));

    public LegacyKeyFilesTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private string P(params string[] parts) => Path.Combine([_root, .. parts]);

    private static string Write(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        return path;
    }

    // Where the old code put the plugin config for an install root (no exe there: the first layout).
    private string PluginConfigUnder(string installRoot) =>
        Path.Combine(installRoot, "Bellwright", "Binaries", "Win64", "Mods", "Hearth", "hearth.config.json");

    [Fact]
    public void Removes_the_hmac_key_and_keeps_the_snapshot_list_beside_it()
    {
        var key = Write(P("data", "hmac.key"), Key);
        var db = Write(P("data", "hearth.db"), "sqlite");
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = key, GameInstallRoot = "" }, log, null);

        outcome.Removed.Should().Equal(Path.GetFullPath(key));
        outcome.Left.Should().BeEmpty();
        File.Exists(key).Should().BeFalse();
        File.Exists(db).Should().BeTrue();
        log.Entries.Should().ContainSingle().Which.Text.Should().Contain("removed").And.Contain(key);
    }

    [Fact]
    public void Removes_the_plugin_config_beside_the_game_exe_and_keeps_the_folder()
    {
        var root = P("game");
        var cfg = Write(PluginConfigUnder(root), PluginConfig);
        var log = new ListLogger<LegacyKeyFilesTests>();

        LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = "", GameInstallRoot = root }, log, null)
            .Removed.Should().Equal(Path.GetFullPath(cfg));

        File.Exists(cfg).Should().BeFalse();
        Directory.Exists(Path.GetDirectoryName(cfg)).Should().BeTrue("only the file goes, by its exact name");
        log.Entries.Should().ContainSingle();
    }

    [Fact]
    public void Removes_the_copy_under_the_default_install_root_on_a_panel_server()
    {
        // The panel leaves GameInstallRoot empty; the first panel start on 2026-06-15 used the default root.
        var defaultRoot = P("default-root");
        var cfg = Write(PluginConfigUnder(defaultRoot), PluginConfig);
        var key = Write(P("data", "hmac.key"), Key);
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = key, GameInstallRoot = "" }, log, defaultRoot);

        outcome.Removed.Should().BeEquivalentTo(new[] { Path.GetFullPath(key), Path.GetFullPath(cfg) });
        log.Entries.Should().ContainSingle("both removals share one log line");
    }

    [Fact]
    public void Nothing_there_means_no_log_line()
    {
        var log = new ListLogger<LegacyKeyFilesTests>();
        var outcome = LegacyKeyFiles.Remove(
            new HearthServerOptions { HmacKeyPath = P("data", "hmac.key"), GameInstallRoot = P("game") }, log, P("default-root"));

        outcome.Removed.Should().BeEmpty();
        outcome.Left.Should().BeEmpty();
        log.Entries.Should().BeEmpty();
    }

    [Fact]
    public void A_key_path_with_another_name_is_never_touched()
    {
        var other = Write(P("keys", "important.pem"), Key);
        var log = new ListLogger<LegacyKeyFilesTests>();

        LegacyKeyFiles.Candidates(new HearthServerOptions { HmacKeyPath = other, GameInstallRoot = "" }, null)
            .Should().BeEmpty();
        LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = other, GameInstallRoot = "" }, log, null);

        File.ReadAllText(other).Should().Be(Key);
        log.Entries.Should().BeEmpty();
    }

    [Fact]
    public void A_file_that_does_not_hold_what_the_old_code_wrote_stays()
    {
        var key = Write(P("data", "hmac.key"), "something else");
        var root = P("game");
        var cfg = Write(PluginConfigUnder(root), "{ \"SomeMod\": true }");
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = key, GameInstallRoot = root }, log, null);

        outcome.Removed.Should().BeEmpty();
        outcome.Left.Should().HaveCount(2);
        File.Exists(key).Should().BeTrue();
        File.Exists(cfg).Should().BeTrue();
        log.Entries.Should().ContainSingle().Which.Level.Should().Be(LogLevel.Warning);
    }

    [Fact]
    public void A_folder_with_the_exact_name_stays()
    {
        var dir = P("data", "hmac.key");
        Directory.CreateDirectory(dir);
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = dir, GameInstallRoot = "" }, log, null);

        outcome.Removed.Should().BeEmpty();
        outcome.Left.Should().ContainSingle().Which.Should().Contain("not a plain file");
        Directory.Exists(dir).Should().BeTrue();
    }

    [Fact]
    public void A_link_with_the_exact_name_stays_and_its_target_is_untouched()
    {
        var target = Write(P("elsewhere", "real.key"), Key);
        var link = P("data", "hmac.key");
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        try
        {
            File.CreateSymbolicLink(link, target);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            return; // this machine may not create links (Windows without the right); Linux CI runs it
        }
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = link, GameInstallRoot = "" }, log, null);

        outcome.Removed.Should().BeEmpty();
        outcome.Left.Should().ContainSingle().Which.Should().Contain("a link");
        new FileInfo(link).LinkTarget.Should().NotBeNull("the link itself stays");
        File.ReadAllText(target).Should().Be(Key);
        log.Entries.Should().ContainSingle().Which.Level.Should().Be(LogLevel.Warning);
    }

    // Security 2026-11-16: the folders the old code made (data; Mods and Mods\Hearth) may not be links either. The owner
    // can write the server and game folders, so a linked folder could point the delete at a file somewhere else.
    private static bool TryLinkFolder(string link, string target)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        try
        {
            Directory.CreateSymbolicLink(link, target);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            return false; // this machine may not create links (Windows without the right); Linux CI runs it
        }
    }

    [Fact]
    public void A_linked_data_folder_keeps_the_key_and_the_file_it_points_at()
    {
        var real = Write(P("elsewhere", "hmac.key"), Key);
        if (!TryLinkFolder(P("data"), P("elsewhere"))) return;
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = P("data", "hmac.key"), GameInstallRoot = "" }, log, null);

        outcome.Removed.Should().BeEmpty();
        outcome.Left.Should().ContainSingle().Which.Should().Contain("is a link").And.Contain(P("data"));
        File.ReadAllText(real).Should().Be(Key);
        log.Entries.Should().ContainSingle().Which.Level.Should().Be(LogLevel.Warning);
    }

    [Theory]
    [InlineData("Mods")]
    [InlineData("Hearth")]
    public void A_linked_Mods_or_Hearth_folder_keeps_the_plugin_config(string linkedLevel)
    {
        var root = P("game");
        var cfg = PluginConfigUnder(root);
        var hearthDir = Path.GetDirectoryName(cfg)!;
        var modsDir = Path.GetDirectoryName(hearthDir)!;
        string real;
        if (linkedLevel == "Mods")
        {
            real = Write(P("other", "Hearth", "hearth.config.json"), PluginConfig);
            if (!TryLinkFolder(modsDir, P("other"))) return;
        }
        else
        {
            real = Write(P("other", "hearth.config.json"), PluginConfig);
            Directory.CreateDirectory(modsDir);
            if (!TryLinkFolder(hearthDir, P("other"))) return;
        }
        File.Exists(cfg).Should().BeTrue("the config is reached through the link");
        var log = new ListLogger<LegacyKeyFilesTests>();

        var outcome = LegacyKeyFiles.Remove(new HearthServerOptions { HmacKeyPath = "", GameInstallRoot = root }, log, null);

        outcome.Removed.Should().BeEmpty();
        outcome.Left.Should().ContainSingle().Which.Should().Contain("is a link")
            .And.Contain(linkedLevel == "Mods" ? modsDir : hearthDir);
        File.ReadAllText(real).Should().Be(PluginConfig);
    }

    [Fact]
    public void The_owned_folders_are_the_keys_own_folder_and_Mods_and_Hearth()
    {
        LegacyKeyFiles.OwnedFolders(P("data", "hmac.key")).Should().Equal(P("data"));
        var cfg = PluginConfigUnder(P("game"));
        var hearthDir = Path.GetDirectoryName(cfg)!;
        LegacyKeyFiles.OwnedFolders(cfg).Should().Equal(hearthDir, Path.GetDirectoryName(hearthDir)!);
    }
}
