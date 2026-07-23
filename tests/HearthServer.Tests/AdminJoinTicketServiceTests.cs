using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace HearthServer.Tests;

public sealed class AdminJoinTicketServiceTests
{
    private const string AllowedSteamId = "76561197971106764";

    [Fact]
    public void IssuePersistsBoundShortLivedTicket()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-admin-ticket-tests", Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "tickets.tsv");
        try
        {
            var service = Create(path, AllowedSteamId);
            var before = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

            var issued = service.Issue(AllowedSteamId, "::ffff:203.0.113.42");

            Assert.NotNull(issued);
            Assert.Matches("^[0-9a-f]{64}$", issued!.Token);
            Assert.InRange(issued.ExpiresUnix, before + 175, before + 185);
            var row = File.ReadAllText(path).Trim().Split('\t');
            Assert.Equal(4, row.Length);
            Assert.Equal(issued.Token, row[0]);
            Assert.Equal(AllowedSteamId, row[1]);
            Assert.Equal(issued.ExpiresUnix.ToString(), row[2]);
            Assert.Equal("203.0.113.42", row[3]);
        }
        finally
        {
            if (Directory.Exists(root))
                Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void IssueRejectsUnconfiguredOrMalformedIdentityAndAddress()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-admin-ticket-tests", Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "tickets.tsv");
        try
        {
            var service = Create(path, AllowedSteamId);

            Assert.Null(service.Issue("76561197971106765", "203.0.113.42"));
            Assert.Null(service.Issue("not-steam", "203.0.113.42"));
            Assert.Null(service.Issue(AllowedSteamId, "not-an-ip"));
            Assert.Equal("", File.ReadAllText(path));
        }
        finally
        {
            if (Directory.Exists(root))
                Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void NewProcessInstanceClearsPriorTickets()
    {
        var root = Path.Combine(Path.GetTempPath(), "hearth-admin-ticket-tests", Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "tickets.tsv");
        try
        {
            var first = Create(path, AllowedSteamId);
            Assert.NotNull(first.Issue(AllowedSteamId, "203.0.113.42"));
            Assert.NotEmpty(File.ReadAllText(path));

            _ = Create(path, AllowedSteamId);

            Assert.Equal("", File.ReadAllText(path));
        }
        finally
        {
            if (Directory.Exists(root))
                Directory.Delete(root, recursive: true);
        }
    }

    private static AdminJoinTicketService Create(string path, params string[] allowed) =>
        new(
            Options.Create(new HearthServerOptions
            {
                AdminSteamIds = [.. allowed],
                AdminJoinTicketPath = path,
            }),
            NullLogger<AdminJoinTicketService>.Instance);
}
