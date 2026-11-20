using System.Diagnostics.CodeAnalysis;

namespace HearthServer.Services;

/// <summary>
/// The one SteamID64 check on the server: a personal Steam account (individual type, public universe, account number
/// 1 to 2^32-1). That is exactly 17 ASCII digits from 76561197960265729 to 76561202255233023 inclusive. Every account
/// number so far gives an ID that starts 7656119; newer accounts will start 7656120, so the check never looks at a
/// prefix. No trimming, no other scripts' digits.
/// </summary>
public static class SteamId64
{
    public const string Min = "76561197960265729";
    public const string Max = "76561202255233023";

    public static bool IsValid([NotNullWhen(true)] string? value)
    {
        if (value is null || value.Length != 17) return false;
        foreach (var c in value)
        {
            if (c is < '0' or > '9') return false;
        }
        // Same length, ASCII digits only: ordinal order is numeric order.
        return string.CompareOrdinal(value, Min) >= 0 && string.CompareOrdinal(value, Max) <= 0;
    }
}
