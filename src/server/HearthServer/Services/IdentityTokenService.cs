using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using HearthServer.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace HearthServer.Services;

/// <summary>
/// Signs the short-lived join tokens the HearthIdentity host mod checks (src/native/Hearth.Identity, IdentityCore).
/// Token = hex(payload) "." hex(HMAC-SHA256(key, payload)), payload = "v1|steam64|expires unix|nonce hex". The key is
/// 32 random bytes kept as 64 hex in &lt;identity folder&gt;/token.key, minted on first run; the host mod reads the same
/// file. A token is only issued after Steam has checked the player's session ticket (SteamTicketVerifier).
/// </summary>
public sealed class IdentityTokenService
{
    private static readonly Regex Steam64Regex = new(@"^7656119[0-9]{10}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex ComputerIdRegex = new(
        @"^[A-Za-z0-9_.\-]{1,64}-[0-9A-Fa-f]{32}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    internal const int MaxLifetimeSeconds = 600;

    private readonly byte[] _key;
    private readonly int _lifetime;

    public IdentityTokenService(IOptions<HearthServerOptions> options, ILogger<IdentityTokenService> log)
    {
        var opts = options.Value.Identity;
        Folder = ResolveFolder(opts.Directory);
        _lifetime = Math.Clamp(opts.TokenLifetimeSeconds, 60, MaxLifetimeSeconds);
        System.IO.Directory.CreateDirectory(Folder);
        var path = Path.Combine(Folder, "token.key");
        if (File.Exists(path))
        {
            var hex = File.ReadAllText(path).Trim();
            if (hex.Length != 64) throw new InvalidOperationException($"identity token key {path} must be 64 hex characters");
            _key = Convert.FromHexString(hex);
        }
        else
        {
            _key = RandomNumberGenerator.GetBytes(32);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, Convert.ToHexString(_key).ToLowerInvariant());
            File.Move(tmp, path, overwrite: true);
            log.LogInformation("Identity: generated a new token key in {Folder}", Folder);
        }
    }

    internal IdentityTokenService(byte[] key, string folder, int lifetimeSeconds = MaxLifetimeSeconds)
    {
        _key = key;
        Folder = folder;
        _lifetime = Math.Clamp(lifetimeSeconds, 60, MaxLifetimeSeconds);
    }

    /// <summary>The identity folder (token.key, steam-map.tsv), absolute.</summary>
    public string Folder { get; }

    public static bool IsValidSteam64([NotNullWhen(true)] string? s) => s is not null && Steam64Regex.IsMatch(s);
    public static bool IsComputerId([NotNullWhen(true)] string? s) => s is not null && ComputerIdRegex.IsMatch(s);

    internal static string ResolveFolder(string configured)
    {
        var dir = string.IsNullOrWhiteSpace(configured) ? "data/identity" : configured;
        return Path.GetFullPath(Path.IsPathRooted(dir) ? dir : Path.Combine(AppContext.BaseDirectory, dir));
    }

    public (string Token, long ExpiresUnix) Issue(string steam64, long? nowUnix = null)
    {
        if (!IsValidSteam64(steam64)) throw new ArgumentException("not a Steam64 id", nameof(steam64));
        var now = nowUnix ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var expires = now + _lifetime;
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant();
        return (Sign(_key, $"v1|{steam64}|{expires}|{nonce}"), expires);
    }

    internal static string Sign(byte[] key, string payload)
    {
        var bytes = Encoding.ASCII.GetBytes(payload);
        var mac = HMACSHA256.HashData(key, bytes);
        return Convert.ToHexString(bytes).ToLowerInvariant() + "." + Convert.ToHexString(mac).ToLowerInvariant();
    }

    /// <summary>
    /// Signature, version, Steam ID and expiry (not one-use: the host mod spends the token at login; HearthServer
    /// reads it afterwards from the game log to learn the computer id).
    /// </summary>
    public bool Verify(string? token, string? steam64, long? nowUnix = null)
    {
        if (string.IsNullOrEmpty(token) || token.Length > 512 || !IsValidSteam64(steam64)) return false;
        var dot = token.IndexOf('.');
        if (dot <= 0) return false;
        byte[] payload, mac;
        try
        {
            payload = Convert.FromHexString(token[..dot]);
            mac = Convert.FromHexString(token[(dot + 1)..]);
        }
        catch (FormatException) { return false; }
        if (mac.Length != 32 || !CryptographicOperations.FixedTimeEquals(mac, HMACSHA256.HashData(_key, payload))) return false;
        var parts = Encoding.ASCII.GetString(payload).Split('|');
        if (parts.Length != 4 || parts[0] != "v1" || parts[1] != steam64) return false;
        if (!long.TryParse(parts[2], out var expires)) return false;
        var now = nowUnix ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        return expires >= now && expires <= now + MaxLifetimeSeconds + 60;
    }
}
