using HearthServer.Configuration;
using HearthServer.Services;
using FluentAssertions;
using Xunit;

namespace HearthServer.Tests;

// Bellwright's own build banner reads "LogInit: Build: UE5-CL-0" (its build system leaves the
// changelist at 0), so the app showed "Bellwright UE5-CL-0", which names nothing. The supervisor now
// ignores an empty changelist and reports the install's Steam build from its appmanifest.
[Collection("HearthVersionInfo")]
public class HearthVersionInfoTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "hearth-vi-" + Guid.NewGuid().ToString("N"));

    public HearthVersionInfoTests()
    {
        HearthVersionInfo.ResetBuildForTests();
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        HearthVersionInfo.ResetBuildForTests();
        try { Directory.Delete(_root, recursive: true); } catch (IOException) { }
    }

    private void WriteManifest(string root, string buildId)
    {
        Directory.CreateDirectory(Path.Combine(root, "steamapps"));
        File.WriteAllText(Path.Combine(root, "steamapps", "appmanifest_1812450.acf"),
            "\"AppState\"\n{\n\t\"appid\"\t\t\"1812450\"\n\t\"buildid\"\t\t\"" + buildId + "\"\n\t\"StateFlags\"\t\t\"4\"\n}\n");
    }

    [Theory]
    [InlineData("UE5-CL-0")]
    [InlineData("++UE5+Release-5.7-CL-0")]
    public void An_empty_changelist_banner_is_not_a_build(string banner)
    {
        HearthVersionInfo.SetHearthBuild(banner);
        HearthVersionInfo.HearthBuild.Should().Be("unknown");
    }

    [Fact]
    public void A_real_banner_is_still_reported_when_no_manifest_exists()
    {
        HearthVersionInfo.SetHearthBuild("UE5-CL-24840601");
        HearthVersionInfo.HearthBuild.Should().Be("UE5-CL-24840601");
    }

    [Fact]
    public void The_steam_build_is_read_from_the_folder_above_the_user_dir_and_wins_over_the_banner()
    {
        var server = Path.Combine(_root, "991377");
        WriteManifest(server, "24840601");
        var opts = new HearthServerOptions { GameInstallRoot = "", GameUserDir = Path.Combine(server, "UserDir") };

        HearthVersionInfo.TrySetSteamBuild(HearthLogTailService.SteamManifestRoots(opts)).Should().BeTrue();
        HearthVersionInfo.HearthBuild.Should().Be("24840601");
        HearthVersionInfo.SetHearthBuild("UE5-CL-12345");
        HearthVersionInfo.HearthBuild.Should().Be("24840601");
    }

    [Fact]
    public void A_self_hosted_install_root_is_read_first()
    {
        var install = Path.Combine(_root, "game");
        WriteManifest(install, "25000001");
        WriteManifest(_root, "1");
        var opts = new HearthServerOptions { GameInstallRoot = install, GameUserDir = Path.Combine(_root, "UserDir") };

        HearthVersionInfo.ReadSteamBuildId(HearthLogTailService.SteamManifestRoots(opts)).Should().Be("25000001");
    }

    [Fact]
    public void No_manifest_leaves_the_build_unknown()
    {
        var opts = new HearthServerOptions { GameInstallRoot = Path.Combine(_root, "none"), GameUserDir = Path.Combine(_root, "x", "UserDir") };
        HearthVersionInfo.TrySetSteamBuild(HearthLogTailService.SteamManifestRoots(opts)).Should().BeFalse();
        HearthVersionInfo.HearthBuild.Should().Be("unknown");
    }
}
