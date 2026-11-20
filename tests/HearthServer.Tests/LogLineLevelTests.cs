using HearthServer.Services;
using FluentAssertions;
using Microsoft.Extensions.Logging;
using Xunit;

namespace HearthServer.Tests;

// 2026-11-11: a player's normal leave was mirrored as an Error line; a Steam login drop and its
// recovery were never logged after the first "login OK".
public class LogLineLevelTests
{
    [Theory]
    // the three normal-leave lines read on hosted servers (2026-11-11), word for word
    [InlineData("[2026.11.10-23.30.57:610][939]LogNet:  - Result=ControlChannelClose, ErrorContext=\"ControlChannelClose\"", LogLevel.Information)]
    [InlineData("[2026.11.11-06.28.18:261][233]LogNet: Initiating graceful close. CloseReason: (Result=ControlChannelClose, ErrorContext=\"ControlChannelClose\")", LogLevel.Information)]
    [InlineData("[2026.11.11-06.28.18:272][234]LogNet:  - Result=ConnectionTimeout, ErrorContext=\"ConnectionTimeout\"", LogLevel.Information)]
    // the game's own verbosity still wins on those lines
    [InlineData("[2026.11.11-06.28.18:272][234]LogNet: Warning: close - Result=ConnectionTimeout, ErrorContext=\"ConnectionTimeout\"", LogLevel.Warning)]
    [InlineData("[2026.11.11-06.28.18:272][234]LogNet: Error: close - Result=ControlChannelClose, ErrorContext=\"ControlChannelClose\"", LogLevel.Error)]
    [InlineData("LogNet: Fatal: close - Result=ControlChannelClose, ErrorContext=\"ControlChannelClose\"", LogLevel.Error)]
    // any other close result keeps today's level
    [InlineData("[2026.11.11-06.28.18:272][234]LogNet:  - Result=HostClosedConnection, ErrorContext=\"HostClosedConnection\"", LogLevel.Error)]
    // everything else exactly as before
    [InlineData("[2026.11.11-06.28.18:272][234]LogWindows: Error: appError called: Assertion failed", LogLevel.Error)]
    [InlineData("[2026.11.11-06.28.18:272][234]LogStreaming: Warning: Failed to read file", LogLevel.Warning)]
    [InlineData("[2026.11.11-06.28.18:272][234]LogTemp: world saved", LogLevel.Information)]
    [InlineData("[2026.11.11-06.28.18:272][234]LogTemp: errors=0 in this pass", LogLevel.Error)]
    public void PassThroughLevel_logs_a_normal_leave_as_information_and_keeps_real_errors(string line, LogLevel expected)
    {
        HearthLogTailService.PassThroughLevel(line).Should().Be(expected);
    }

    private const int Connected = 101, ConnectFailure = 102, Disconnected = 103, AuthResponse = 143;

    private static SteamGameServerTicketVerifier.SteamLoginLine[] Run(params int[] callbacks)
    {
        var state = SteamGameServerTicketVerifier.SteamLogin.NeverConnected;
        return callbacks.Select(id => SteamGameServerTicketVerifier.NextLoginLine(id, ref state)).ToArray();
    }

    [Fact]
    public void Steam_login_logs_ok_once_while_it_stays_up()
    {
        Run(Connected, AuthResponse, Connected).Should().Equal(
            SteamGameServerTicketVerifier.SteamLoginLine.FirstOk,
            SteamGameServerTicketVerifier.SteamLoginLine.None,
            SteamGameServerTicketVerifier.SteamLoginLine.None);
    }

    [Fact]
    public void Steam_login_drop_logs_lost_then_ok_again()
    {
        // Steam's maintenance: the login drops, retries fail, then it comes back (2026-11-10)
        Run(Connected, Disconnected, ConnectFailure, ConnectFailure, Connected).Should().Equal(
            SteamGameServerTicketVerifier.SteamLoginLine.FirstOk,
            SteamGameServerTicketVerifier.SteamLoginLine.Lost,
            SteamGameServerTicketVerifier.SteamLoginLine.Failed,
            SteamGameServerTicketVerifier.SteamLoginLine.Failed,
            SteamGameServerTicketVerifier.SteamLoginLine.OkAgain);
    }

    [Fact]
    public void Steam_login_failure_without_a_disconnect_still_ends_in_ok_again()
    {
        Run(Connected, ConnectFailure, Connected).Should().Equal(
            SteamGameServerTicketVerifier.SteamLoginLine.FirstOk,
            SteamGameServerTicketVerifier.SteamLoginLine.Failed,
            SteamGameServerTicketVerifier.SteamLoginLine.OkAgain);
    }

    [Fact]
    public void Steam_login_that_never_came_up_logs_failures_then_the_first_ok()
    {
        Run(ConnectFailure, Disconnected, Connected, Disconnected, Disconnected, Connected).Should().Equal(
            SteamGameServerTicketVerifier.SteamLoginLine.Failed,
            SteamGameServerTicketVerifier.SteamLoginLine.None,
            SteamGameServerTicketVerifier.SteamLoginLine.FirstOk,
            SteamGameServerTicketVerifier.SteamLoginLine.Lost,
            SteamGameServerTicketVerifier.SteamLoginLine.None,
            SteamGameServerTicketVerifier.SteamLoginLine.OkAgain);
    }
}
