using System.Reflection;
using System.Text.RegularExpressions;

namespace HearthServer.Services;

/// <summary>
/// Single source of truth for version strings surfaced to operators, A2S
/// queries, and the startup banner. Hearth's own version comes from the
/// assembly; Bellwright's build number is read at runtime from the host's UE log.
/// </summary>
public static class HearthVersionInfo
{
    public static string HearthVersion { get; } = ResolveHearthVersion();

    public static string HearthBuild { get; private set; } = "unknown";

    private static bool _steamBuildKnown;

    /// <summary>
    /// Called once the host log is parsed. Subsequent A2S query responses +
    /// banner refreshes include it. Bellwright's own banner reads "UE5-CL-0": its build
    /// system leaves the changelist at 0, so that string names no build and is ignored
    /// (the app hides an unknown build). The Steam build read from the install manifest
    /// wins when it was found.
    /// </summary>
    public static void SetHearthBuild(string build)
    {
        if (string.IsNullOrWhiteSpace(build)) return;
        build = build.Trim();
        if (IsEmptyChangelist(build) || _steamBuildKnown) return;
        HearthBuild = build;
    }

    internal static bool IsEmptyChangelist(string build) =>
        Regex.IsMatch(build, @"(^|[-+])CL-0$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// The Steam build id of the game install (steamapps/appmanifest_1812450.acf, "buildid"),
    /// from the first root that has it; null when none does.
    /// </summary>
    public static string? ReadSteamBuildId(IEnumerable<string?> roots)
    {
        foreach (var root in roots)
        {
            if (string.IsNullOrWhiteSpace(root)) continue;
            try
            {
                var manifest = Path.Combine(root, "steamapps", "appmanifest_1812450.acf");
                if (!File.Exists(manifest)) continue;
                var m = Regex.Match(File.ReadAllText(manifest), "\"buildid\"\\s+\"(?<id>\\d+)\"",
                    RegexOptions.CultureInvariant);
                if (m.Success) return m.Groups["id"].Value;
            }
            catch (IOException)
            {
                // unreadable manifest: try the next root
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
        return null;
    }

    /// <summary>Reports the install's Steam build instead of the UE banner. True when found.</summary>
    public static bool TrySetSteamBuild(IEnumerable<string?> roots)
    {
        var id = ReadSteamBuildId(roots);
        if (id is null) return false;
        HearthBuild = id;
        _steamBuildKnown = true;
        return true;
    }

    internal static void ResetBuildForTests()
    {
        HearthBuild = "unknown";
        _steamBuildKnown = false;
    }

    private static string ResolveHearthVersion()
    {
        var asm = Assembly.GetExecutingAssembly();
        var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(info))
        {
            // Strip "+commitsha" suffix MSBuild appends in default release builds.
            var plus = info.IndexOf('+');
            return plus > 0 ? info[..plus] : info;
        }
        return asm.GetName().Version?.ToString(3) ?? "0.0.0";
    }
}
