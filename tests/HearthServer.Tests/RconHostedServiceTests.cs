using FluentAssertions;
using HearthServer.Services;

namespace HearthServer.Tests;

public sealed class RconHostedServiceTests
{
    [Fact]
    public void GameSaveMarkerIsScopedToTheGameplayPort()
    {
        var path = RconHostedService.GameSaveMarkerPath(12377, @"C:\Hearth\Logs\bw.pid", @"C:\Windows");

        path.Replace('\\', '/').Should().Be("C:/Hearth/Logs/hearth_force_save_12377.marker");
    }

    [Fact]
    public void GameSaveMarkerFallsBackToWindowsTempWithoutAPidFile()
    {
        var path = RconHostedService.GameSaveMarkerPath(12377, "", @"C:\Windows");

        path.Replace('\\', '/').Should().Be("C:/Windows/Temp/hearth_force_save_12377.marker");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(65536)]
    public void GameSaveMarkerRejectsInvalidPorts(int port)
    {
        var action = () => RconHostedService.GameSaveMarkerPath(port, @"C:\Hearth\Logs\bw.pid", @"C:\Windows");

        action.Should().Throw<ArgumentOutOfRangeException>();
    }
}
