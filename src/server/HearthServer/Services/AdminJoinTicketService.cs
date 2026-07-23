using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using HearthServer.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Issues short-lived, one-use admin tickets after the HTTP layer has already
/// authenticated the launcher with the server's RCON password. The UE4SS host
/// overlay consumes the server-local registry and binds each ticket to the
/// configured Steam64 ID and the launcher's public source address.
/// </summary>
public sealed class AdminJoinTicketService
{
    private const int TicketLifetimeSeconds = 180;
    private const int MaxOutstandingTickets = 64;
    private static readonly Regex Steam64Regex = new(
        @"^7656119[0-9]{10}$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private readonly ILogger<AdminJoinTicketService> _log;
    private readonly HashSet<string> _allowedSteamIds;
    private readonly string _path;
    private readonly object _gate = new();
    private readonly List<TicketRecord> _tickets = [];

    public AdminJoinTicketService(
        IOptions<HearthServerOptions> options,
        ILogger<AdminJoinTicketService> log)
    {
        _log = log;
        var opts = options.Value;
        _allowedSteamIds = (opts.AdminSteamIds ?? [])
            .Where(IsValidSteam64)
            .ToHashSet(StringComparer.Ordinal);
        _path = ResolvePath(opts.AdminJoinTicketPath);

        // Tickets are process-lifetime credentials. A restarted HearthServer
        // must never honor a registry left by the prior process.
        lock (_gate)
        {
            WriteRegistry();
        }
    }

    public IssuedTicket? Issue(string? steamId, string? remoteAddress)
    {
        var normalizedSteamId = (steamId ?? "").Trim();
        var normalizedAddress = NormalizeAddress(remoteAddress);
        if (!IsValidSteam64(normalizedSteamId)
            || !_allowedSteamIds.Contains(normalizedSteamId)
            || normalizedAddress is null)
        {
            return null;
        }

        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            _tickets.RemoveAll(t => t.ExpiresUnix <= now);
            while (_tickets.Count >= MaxOutstandingTickets)
                _tickets.RemoveAt(0);

            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            var record = new TicketRecord(
                token,
                normalizedSteamId,
                checked(now + TicketLifetimeSeconds),
                normalizedAddress);
            _tickets.Add(record);
            WriteRegistry();

            _log.LogInformation(
                "Issued one-use Bellwright admin join ticket for configured Steam64 ending {Suffix}",
                normalizedSteamId[^4..]);
            return new IssuedTicket(record.Token, record.ExpiresUnix);
        }
    }

    public static bool IsValidSteam64(string? value) =>
        value is not null && Steam64Regex.IsMatch(value);

    internal string RegistryPath => _path;

    private static string? NormalizeAddress(string? value)
    {
        if (!IPAddress.TryParse(value, out var address))
            return null;
        if (address.IsIPv4MappedToIPv6)
            address = address.MapToIPv4();
        return address.ToString().ToLowerInvariant();
    }

    private string ResolvePath(string? configured)
    {
        var value = string.IsNullOrWhiteSpace(configured)
            ? "data/admin-join-tickets.tsv"
            : configured.Trim();
        return Path.GetFullPath(value, AppContext.BaseDirectory);
    }

    private void WriteRegistry()
    {
        var directory = Path.GetDirectoryName(_path)
            ?? throw new InvalidOperationException("Admin join ticket path has no parent directory");
        Directory.CreateDirectory(directory);

        var content = string.Join(
            "\r\n",
            _tickets.Select(t => $"{t.Token}\t{t.SteamId}\t{t.ExpiresUnix}\t{t.RemoteAddress}"));
        if (content.Length > 0)
            content += "\r\n";

        var tempPath = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(tempPath, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            File.Move(tempPath, _path, overwrite: true);
        }
        finally
        {
            try
            {
                if (File.Exists(tempPath))
                    File.Delete(tempPath);
            }
            catch { }
        }
    }

    public sealed record IssuedTicket(string Token, long ExpiresUnix);

    private sealed record TicketRecord(
        string Token,
        string SteamId,
        long ExpiresUnix,
        string RemoteAddress);
}
