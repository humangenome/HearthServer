using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace HearthServer.Services;

/// <summary>
/// Valve's Steam libraries for the Steam ticket check, loaded only by full path and only after they are checked.
/// HearthServer may run with an administrator's rights, so a library it loads must be Valve's and must come from a place
/// no ordinary account can change.
///   * steamclient64.dll and the two libraries it needs (tier0_s64.dll, vstdlib_s64.dll) come from ONE folder: the one
///     Identity:SteamClientPath names (the file or its folder). Nothing else is searched: not HearthServer's own folder,
///     not the installed Steam client's. Empty = Steam checks stay off.
///   * Every file is opened first and held open until it is loaded (others may read it; nobody may write, rename or
///     delete it, and its folder cannot be renamed while it is open), so what was checked is what loads.
///   * Each must be a plain file reached by its own path (no link or junction anywhere on the way: the open file's real
///     path must be the path asked for) and carry a valid Authenticode signature whose signer is Valve Corp.
///   * When HearthServer runs elevated, the folder and each file must also be owned by Administrators, SYSTEM or
///     TrustedInstaller, with no other account able to write, delete, or change their rights.
///   * tier0_s64.dll and vstdlib_s64.dll load first, so steamclient64.dll's own imports are the checked ones.
///   * The Steam API library (the game's steam_api64.dll) gets the same file and signature checks (its folder may be
///     reached through a link: a host can keep a server's folder on another drive), and no Steam client library may sit
///     beside it unless that is the checked folder (the Steam API library could pick that one up). It loads with
///     LOAD_LIBRARY_SEARCH_SYSTEM32, so the libraries it imports come from System32 only, never from the game folder
///     beside it, which the game's owner may be able to write (Security, 2026-11-16; Bellwright's steam_api64.dll imports
///     only KERNEL32, ADVAPI32 and SHELL32).
/// Anything that fails: nothing more loads, and the caller turns Steam checks off (players keep the character of the
/// computer they join from).
/// </summary>
public class SteamLibraryGuard
{
    /// <summary>The client files, in the order they load.</summary>
    public static readonly string[] ClientFiles = ["tier0_s64.dll", "vstdlib_s64.dll", "steamclient64.dll"];

    public sealed record Loaded(bool Ok, string Detail, IntPtr Handle);

    // ------------ seams (tests replace these; the defaults are the real Windows checks)

    /// <summary>True when this process runs elevated (an administrator's full rights, or SYSTEM).</summary>
    public virtual bool IsElevated => Environment.IsPrivilegedProcess;

    /// <summary>null when the open file carries a valid Authenticode signature from Valve Corp., else why not.</summary>
    public virtual string? SignatureProblem(string path, SafeFileHandle open) =>
        OperatingSystem.IsWindows() ? WindowsSignatureProblem(path, open) : "signatures can only be checked on Windows";

    /// <summary>null when only Administrators, SYSTEM or TrustedInstaller own and can change it, else why not.</summary>
    public virtual string? RightsProblem(string path, bool isFolder) =>
        OperatingSystem.IsWindows() ? WindowsRightsProblem(path, isFolder) : "rights can only be checked on Windows";

    /// <summary>The real path of an open file, or null.</summary>
    public virtual string? RealPath(SafeFileHandle open) => OperatingSystem.IsWindows() ? WindowsFinalPath(open) : null;

    /// <summary>Loads a library by its full path.</summary>
    public virtual IntPtr Load(string path) => NativeLibrary.Load(path);

    /// <summary>
    /// Loads a library by its full path; the libraries it imports are looked for in System32 only (LoadLibraryEx with
    /// LOAD_LIBRARY_SEARCH_SYSTEM32), never in its own folder. Off Windows, a plain load (there are no Steam checks there).
    /// </summary>
    public virtual IntPtr LoadWithSystemImports(string path) =>
        OperatingSystem.IsWindows() ? WindowsLoadWithSystemImports(path) : NativeLibrary.Load(path);

    /// <summary>LOAD_LIBRARY_SEARCH_SYSTEM32: the only folder searched for the loaded library's imports.</summary>
    public const uint LoadLibrarySearchSystem32 = 0x00000800;

    // ------------ the steps

    /// <summary>
    /// The folder the client files come from: the configured file's folder (it must be named steamclient64.dll) or the
    /// configured folder. null when none is configured or it is not there: there is no search anywhere else.
    /// </summary>
    public string? ClientFolder(string configured)
    {
        if (string.IsNullOrWhiteSpace(configured)) return null;
        var full = Path.GetFullPath(configured);
        if (Directory.Exists(full)) return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!string.Equals(Path.GetFileName(full), "steamclient64.dll", StringComparison.OrdinalIgnoreCase)) return null;
        return File.Exists(full) ? Path.GetDirectoryName(full) : null;
    }

    /// <summary>Checks and loads the three client files from one folder. Detail = the folder, or why it was refused.</summary>
    public Loaded LoadClient(string configured)
    {
        var folder = ClientFolder(configured);
        if (folder is null)
            return new Loaded(false, string.IsNullOrWhiteSpace(configured) ? "Identity:SteamClientPath is not set (no other folder is searched)" : "no steamclient64.dll at the configured path", IntPtr.Zero);
        var files = ClientFiles.Select(f => Path.Combine(folder, f)).ToList();
        var r = CheckAndLoad(folder, files, lockedFolder: IsElevated, exactPath: true);
        return r.Ok ? new Loaded(true, folder, r.Handle) : r;
    }

    /// <summary>Checks and loads the Steam API library. clientFolder = where the checked client files came from.</summary>
    public Loaded LoadApi(string path, string clientFolder)
    {
        var full = Path.GetFullPath(path);
        var folder = Path.GetDirectoryName(full) ?? "";
        if (!string.Equals(folder, clientFolder, StringComparison.OrdinalIgnoreCase))
        {
            foreach (var name in ClientFiles)
                if (File.Exists(Path.Combine(folder, name)) || Directory.Exists(Path.Combine(folder, name)))
                    return new Loaded(false, $"{name} sits beside the Steam API library and is not the checked one", IntPtr.Zero);
        }
        // The game's own folder may be reached through a link (a host can keep a server's folder on another drive), so
        // the real-path check is left out here: the file itself must still be plain, held open, and signed by Valve.
        return CheckAndLoad(folder, [full], lockedFolder: false, exactPath: false, systemImportsOnly: true);
    }

    /// <summary>
    /// Opens every file (read, shared for reading only), checks the folder and each file while they are all held, then
    /// loads them in order and lets go. The handle of the last one loaded. With exactPath, the open file's real path must be
    /// the path asked for (no link or junction anywhere on the way). With systemImportsOnly, each loads with
    /// <see cref="LoadWithSystemImports"/>.
    /// </summary>
    public Loaded CheckAndLoad(string folder, IReadOnlyList<string> files, bool lockedFolder, bool exactPath, bool systemImportsOnly = false)
    {
        var held = new List<FileStream>();
        try
        {
            foreach (var file in files)
            {
                FileStream fs;
                try { fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    return new Loaded(false, $"{Path.GetFileName(file)} could not be opened ({ex.GetType().Name})", IntPtr.Zero);
                }
                held.Add(fs);
            }
            if (IsLink(folder)) return new Loaded(false, "its folder is a link or junction", IntPtr.Zero);
            if (lockedFolder)
            {
                var why = RightsProblem(folder, isFolder: true);
                if (why is not null) return new Loaded(false, $"its folder can be changed by others ({why})", IntPtr.Zero);
            }
            for (var i = 0; i < files.Count; i++)
            {
                var file = files[i];
                var name = Path.GetFileName(file);
                if (IsLink(file)) return new Loaded(false, $"{name} is a link", IntPtr.Zero);
                if (exactPath)
                {
                    var real = RealPath(held[i].SafeFileHandle);
                    if (real is null || !SamePath(real, file)) return new Loaded(false, $"{name} is not reached by its own path", IntPtr.Zero);
                }
                if (lockedFolder)
                {
                    var rights = RightsProblem(file, isFolder: false);
                    if (rights is not null) return new Loaded(false, $"{name} can be changed by others ({rights})", IntPtr.Zero);
                }
                var sig = SignatureProblem(file, held[i].SafeFileHandle);
                if (sig is not null) return new Loaded(false, $"{name}: {sig}", IntPtr.Zero);
            }
            var handle = IntPtr.Zero;
            foreach (var file in files) handle = systemImportsOnly ? LoadWithSystemImports(file) : Load(file);
            return new Loaded(true, folder, handle);
        }
        catch (Exception ex)
        {
            return new Loaded(false, "check failed: " + ex.Message, IntPtr.Zero);
        }
        finally
        {
            foreach (var fs in held) fs.Dispose();
        }
    }

    /// <summary>True when the signer's name is exactly Valve Corp. (common name and organisation).</summary>
    public static bool SignerIsValve(X500DistinguishedName subject)
    {
        string? cn = null, o = null;
        int cnCount = 0, oCount = 0;
        foreach (var rdn in subject.EnumerateRelativeDistinguishedNames())
        {
            if (rdn.HasMultipleElements) return false;
            var oid = rdn.GetSingleElementType().Value;
            if (oid == "2.5.4.3") { cn = rdn.GetSingleElementValue(); cnCount++; }
            else if (oid == "2.5.4.10") { o = rdn.GetSingleElementValue(); oCount++; }
        }
        return cnCount == 1 && oCount == 1 && cn == "Valve Corp." && o == "Valve Corp.";
    }

    internal static bool SamePath(string real, string asked)
    {
        static string Norm(string p)
        {
            if (p.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) p = @"\\" + p[8..];
            else if (p.StartsWith(@"\\?\", StringComparison.Ordinal)) p = p[4..];
            return Path.GetFullPath(p).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        return string.Equals(Norm(real), Norm(asked), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    private static bool IsLink(string path)
    {
        var attrs = File.GetAttributes(path);
        return (attrs & FileAttributes.ReparsePoint) != 0;
    }

    // ------------ Windows

    private static readonly string TrustedInstaller = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

    [SupportedOSPlatform("windows")]
    private static bool Trusted(SecurityIdentifier sid) =>
        sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) || sid.IsWellKnown(WellKnownSidType.LocalSystemSid)
        || sid.Value == TrustedInstaller;

    [SupportedOSPlatform("windows")]
    private static string? WindowsRightsProblem(string path, bool isFolder)
    {
        // any right that can change what is there, or its rights or owner
        const FileSystemRights Changing = FileSystemRights.WriteData | FileSystemRights.AppendData
            | FileSystemRights.WriteExtendedAttributes | FileSystemRights.WriteAttributes | FileSystemRights.Delete
            | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership
            | (FileSystemRights)0x10000000 /* GENERIC_ALL */ | (FileSystemRights)0x40000000 /* GENERIC_WRITE */;
        FileSystemSecurity sec = isFolder ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        if (sec.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner) return "no owner could be read";
        if (!Trusted(owner)) return "owned by " + owner.Value;
        foreach (FileSystemAccessRule rule in sec.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow) continue;
            if (rule.IdentityReference is SecurityIdentifier sid && Trusted(sid)) continue;
            // an inherit-only entry on the folder applies to new files only; every file is checked on its own
            if (isFolder && (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0) continue;
            if ((rule.FileSystemRights & Changing) != 0) return rule.IdentityReference.Value + " can change it";
        }
        return null;
    }

    [SupportedOSPlatform("windows")]
    private static string? WindowsFinalPath(SafeFileHandle open)
    {
        var buf = new char[1024];
        var n = GetFinalPathNameByHandleW(open, buf, (uint)buf.Length, 0);
        return n == 0 || n >= buf.Length ? null : new string(buf, 0, (int)n);
    }

    [SupportedOSPlatform("windows")]
    private static string? WindowsSignatureProblem(string path, SafeFileHandle open)
    {
        // WinVerifyTrust on the open file: the signature must be valid and chain to a trusted root. No revocation
        // lookups (no network wait at start), as Get-AuthenticodeSignature does by default.
        var fileInfo = new WinTrustFileInfo
        {
            cbStruct = (uint)Marshal.SizeOf<WinTrustFileInfo>(),
            pcwszFilePath = path,
            hFile = open.DangerousGetHandle(),
        };
        var pFile = Marshal.AllocHGlobal(Marshal.SizeOf<WinTrustFileInfo>());
        try
        {
            Marshal.StructureToPtr(fileInfo, pFile, false);
            var data = new WinTrustData
            {
                cbStruct = (uint)Marshal.SizeOf<WinTrustData>(),
                dwUIChoice = 2,            // WTD_UI_NONE
                fdwRevocationChecks = 0,   // WTD_REVOKE_NONE
                dwUnionChoice = 1,         // WTD_CHOICE_FILE
                pFile = pFile,
                dwStateAction = 1,         // WTD_STATEACTION_VERIFY
                dwProvFlags = 0x10,        // WTD_REVOCATION_CHECK_NONE
            };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
            var result = WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            data.dwStateAction = 2;        // WTD_STATEACTION_CLOSE
            WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            Marshal.DestroyStructure<WinTrustFileInfo>(pFile);
            if (result != 0) return $"no valid signature (0x{result:X8})";
        }
        finally
        {
            Marshal.FreeHGlobal(pFile);
        }
        // the signer, read from the same signature WinVerifyTrust just accepted
        // (X509CertificateLoader has no reader for a signed program file; this one reads the signer from its signature)
#pragma warning disable SYSLIB0057
        using var signer = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
        return SignerIsValve(signer.SubjectName) ? null : "not signed by Valve (" + signer.Subject + ")";
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustFileInfo
    {
        public uint cbStruct;
        [MarshalAs(UnmanagedType.LPWStr)] public string pcwszFilePath;
        public IntPtr hFile;
        public IntPtr pgKnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustData
    {
        public uint cbStruct;
        public IntPtr pPolicyCallbackData;
        public IntPtr pSIPClientData;
        public uint dwUIChoice;
        public uint fdwRevocationChecks;
        public uint dwUnionChoice;
        public IntPtr pFile;
        public uint dwStateAction;
        public IntPtr hWVTStateData;
        public IntPtr pwszURLReference;
        public uint dwProvFlags;
        public uint dwUIContext;
        public IntPtr pSignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = false)]
    private static extern int WinVerifyTrust(IntPtr hwnd, ref Guid pgActionID, ref WinTrustData pWVTData);

    [SupportedOSPlatform("windows")]
    private static IntPtr WindowsLoadWithSystemImports(string path)
    {
        var handle = LoadLibraryExW(path, IntPtr.Zero, LoadLibrarySearchSystem32);
        if (handle == IntPtr.Zero)
            throw new DllNotFoundException($"{Path.GetFileName(path)} did not load with System32 imports only (Windows error {Marshal.GetLastPInvokeError()})");
        return handle;
    }

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string lpLibFileName, IntPtr hFile, uint dwFlags);

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle hFile, [Out] char[] lpszFilePath, uint cchFilePath, uint dwFlags);
}
