using HearthServer.Services;
using HearthServer.Configuration;

namespace HearthServer.Tests;

public sealed class HearthProcessSupervisorServiceTests
{
    [Fact]
    public void BuildHostTravelUrlOpensKarveniaListen()
    {
        var url = HearthProcessSupervisorService.BuildHostTravelUrl();

        Assert.Equal("Karvenia_08?listen", url);
    }

    [Fact]
    public void BuildHostTravelOptionsIsListenOnly()
    {
        var options = HearthProcessSupervisorService.BuildHostTravelOptions("save slot 1");

        Assert.Equal("?listen", options);
    }

    [Fact]
    public void ResolveG2ExecutablePathDetectsProjectDirLayout()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-tests", Guid.NewGuid().ToString("N"));
        var exe = Path.Combine(root, "Bellwright", "Binaries", "Win64", "BellwrightGame-Win64-Shipping.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(exe)!);
        File.WriteAllText(exe, "");

        try
        {
            var resolved = HearthProcessSupervisorService.ResolveG2ExecutablePath(new HearthServerOptions
            {
                GameInstallRoot = root,
            });

            Assert.Equal(exe, resolved);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void ResolveG2ExecutablePathPrefersExplicitExecutablePath()
    {
        var explicitPath = Path.Combine(Path.GetTempPath(), "BellwrightGame-Win64-Shipping.exe");

        var resolved = HearthProcessSupervisorService.ResolveG2ExecutablePath(new HearthServerOptions
        {
            GameInstallRoot = @"C:\Hearth\game",
            GameExecutablePath = explicitPath,
        });

        Assert.Equal(Path.GetFullPath(explicitPath), resolved);
    }
}
