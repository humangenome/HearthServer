using System.Reflection;

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

    /// <summary>
    /// Called once the host log is parsed. Subsequent A2S query responses +
    /// banner refreshes include it.
    /// </summary>
    public static void SetHearthBuild(string build)
    {
        if (!string.IsNullOrWhiteSpace(build)) HearthBuild = build.Trim();
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
