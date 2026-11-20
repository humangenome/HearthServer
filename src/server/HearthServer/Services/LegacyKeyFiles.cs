using HearthServer.Configuration;
using Microsoft.Extensions.Logging;

namespace HearthServer.Services;

/// <summary>
/// Removes the key files the named-pipe plugin plane left behind (the plane went in v0.1.100; Security's term
/// for that removal, 2026-11-09). Two files, each by its exact name:
///   - <see cref="HearthServerOptions.HmacKeyPath"/> when its file name is hmac.key (data/hmac.key by default): the
///     pipe's HMAC key, which every start since June created beside HearthServer. hearth.db, which lives in the same
///     folder, is never touched.
///   - Mods\Hearth\hearth.config.json beside the game exe: the pipe path and that key, written when HearthServer
///     launched the game itself (self-hosters), and possibly once under the default install root C:\Hearth\game by
///     the first panel start on 2026-06-15, when its settings section was ignored.
/// A file is removed only when it is a plain file (not a link and not a folder) and holds what the old code wrote
/// (64 hex characters; a JSON file with HmacKeyHex), and when none of the folders the old code made for it is a link
/// or junction either: the key's own folder (data), and Mods and Mods\Hearth for the plugin config (Security,
/// 2026-11-16: the owner can write the server and game folders, so a linked folder could point the delete anywhere).
/// Anything else is left alone. At most one log line per start.
/// </summary>
public static class LegacyKeyFiles
{
    public const string HmacKeyFileName = "hmac.key";
    public const string PluginConfigFileName = "hearth.config.json";

    /// <summary>The install root HearthServer used when no setting reached it (HearthServerOptions' default).</summary>
    public static string? DefaultInstallRoot => OperatingSystem.IsWindows() ? @"C:\Hearth\game" : null;

    public sealed record Outcome(IReadOnlyList<string> Removed, IReadOnlyList<string> Left);

    /// <summary>The exact paths the old code could have written, without duplicates.</summary>
    public static IReadOnlyList<string> Candidates(HearthServerOptions opts, string? defaultInstallRoot)
    {
        var paths = new List<string>();
        void Add(string p)
        {
            var full = Path.GetFullPath(p);
            if (!paths.Contains(full, StringComparer.OrdinalIgnoreCase)) paths.Add(full);
        }

        // HmacKeyService read and wrote HmacKeyPath as given (relative to the working folder).
        if (!string.IsNullOrWhiteSpace(opts.HmacKeyPath)
            && string.Equals(Path.GetFileName(opts.HmacKeyPath), HmacKeyFileName, StringComparison.OrdinalIgnoreCase))
        {
            Add(opts.HmacKeyPath);
        }

        // EmitPluginConfig wrote <folder of ResolveG2ExecutablePath>\Mods\Hearth\hearth.config.json.
        if (!string.IsNullOrWhiteSpace(opts.GameInstallRoot) || !string.IsNullOrWhiteSpace(opts.GameExecutablePath))
        {
            Add(PluginConfigPath(opts));
        }
        if (!string.IsNullOrWhiteSpace(defaultInstallRoot))
        {
            Add(PluginConfigPath(new HearthServerOptions { GameInstallRoot = defaultInstallRoot, GameExecutablePath = "" }));
        }
        return paths;
    }

    public static Outcome Remove(HearthServerOptions opts, ILogger log, string? defaultInstallRoot)
    {
        var removed = new List<string>();
        var left = new List<string>();
        foreach (var path in Candidates(opts, defaultInstallRoot))
        {
            var why = WhyKeep(path);
            if (why is null)
            {
                try
                {
                    File.Delete(path);
                    removed.Add(path);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    left.Add($"{path} (could not delete: {ex.GetType().Name})");
                }
            }
            else if (why.Length > 0)
            {
                left.Add($"{path} ({why})");
            }
        }

        if (left.Count > 0)
        {
            log.LogWarning("Old plugin key files: removed {Removed}; left in place {Left}",
                removed.Count == 0 ? "none" : string.Join(", ", removed), string.Join(", ", left));
        }
        else if (removed.Count > 0)
        {
            log.LogInformation("Old plugin key files: removed {Removed}", string.Join(", ", removed));
        }
        return new Outcome(removed, left);
    }

    private static string PluginConfigPath(HearthServerOptions opts)
    {
        var exe = HearthProcessSupervisorService.ResolveG2ExecutablePath(opts);
        return Path.Combine(Path.GetDirectoryName(exe)!, "Mods", "Hearth", PluginConfigFileName);
    }

    /// <summary>
    /// The folders the old code made for a candidate, nearest first: the key's own folder (data) for hmac.key; Hearth
    /// and Mods for the plugin config. A link or junction at any of them keeps the file where it is.
    /// </summary>
    public static IReadOnlyList<string> OwnedFolders(string path)
    {
        var full = Path.GetFullPath(path);
        var parent = Path.GetDirectoryName(full);
        if (parent is null) return [];
        if (string.Equals(Path.GetFileName(full), PluginConfigFileName, StringComparison.OrdinalIgnoreCase))
        {
            var mods = Path.GetDirectoryName(parent);
            return mods is null ? [parent] : [parent, mods];
        }
        return [parent];
    }

    // null = delete it; "" = nothing there, say nothing; otherwise the reason it stays.
    private static string? WhyKeep(string path)
    {
        FileSystemInfo info = new FileInfo(path);
        if (!info.Exists)
        {
            info = new DirectoryInfo(path);
            if (!info.Exists) return "";
        }
        foreach (var folder in OwnedFolders(path))
        {
            var dir = new DirectoryInfo(folder);
            if (dir.LinkTarget is not null || dir.Attributes.HasFlag(FileAttributes.ReparsePoint))
                return $"its folder {folder} is a link";
        }
        if (info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return "a link";
        if (info is not FileInfo file) return "not a plain file";

        try
        {
            if (string.Equals(file.Name, HmacKeyFileName, StringComparison.OrdinalIgnoreCase))
            {
                if (file.Length > 1024) return "not the old key";
                var hex = File.ReadAllText(path).Trim();
                return hex.Length == 64 && hex.All(Uri.IsHexDigit) ? null : "not the old key";
            }
            if (file.Length > 64 * 1024) return "not the old plugin config";
            return File.ReadAllText(path).Contains("\"HmacKeyHex\"", StringComparison.Ordinal)
                ? null
                : "not the old plugin config";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return $"could not read: {ex.GetType().Name}";
        }
    }
}
