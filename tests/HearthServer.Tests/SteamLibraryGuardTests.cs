using System.Security.Cryptography.X509Certificates;
using FluentAssertions;
using HearthServer.Configuration;
using HearthServer.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Microsoft.Win32.SafeHandles;

namespace HearthServer.Tests;

// Valve's Steam libraries load only by full path, only signed by Valve, held open from the check to the load, and from a
// folder only administrators can change when HearthServer runs elevated (SteamLibraryGuard). The signature, rights and
// load steps stand in here (a "signed" file starts with VALVE); the last tests run the real Windows checks on Windows.
public sealed class SteamLibraryGuardTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "hearth-steamlib-tests", Guid.NewGuid().ToString("N"));

    public SteamLibraryGuardTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private sealed class FakeGuard : SteamLibraryGuard
    {
        public bool Elevated;
        public readonly Dictionary<string, string> Rights = new(StringComparer.OrdinalIgnoreCase);
        public readonly List<string> LoadedFiles = new();
        public readonly List<string> RightsAsked = new();
        public Action<string>? DuringSignature;

        public override bool IsElevated => Elevated;
        public override string? SignatureProblem(string path, SafeFileHandle open)
        {
            DuringSignature?.Invoke(path);
            return File.ReadAllText(path).StartsWith("VALVE", StringComparison.Ordinal) ? null : "not signed by Valve";
        }
        public override string? RightsProblem(string path, bool isFolder)
        {
            RightsAsked.Add(path);
            return Rights.TryGetValue(path, out var why) ? why : null;
        }
        public override string? RealPath(SafeFileHandle open) =>
            OperatingSystem.IsWindows() ? base.RealPath(open) : File.ResolveLinkTarget("/proc/self/fd/" + open.DangerousGetHandle(), false)?.FullName;
        public override IntPtr Load(string path) { LoadedFiles.Add(Path.GetFileName(path)); return (IntPtr)LoadedFiles.Count; }
        public readonly List<string> SystemImportLoads = new();
        public override IntPtr LoadWithSystemImports(string path) { SystemImportLoads.Add(Path.GetFileName(path)); return (IntPtr)(100 + SystemImportLoads.Count); }
    }

    private string Folder(string name, string? tier0 = "VALVE t", string? vstd = "VALVE v", string? client = "VALVE c")
    {
        var dir = Path.Combine(_root, name);
        Directory.CreateDirectory(dir);
        if (tier0 is not null) File.WriteAllText(Path.Combine(dir, "tier0_s64.dll"), tier0);
        if (vstd is not null) File.WriteAllText(Path.Combine(dir, "vstdlib_s64.dll"), vstd);
        if (client is not null) File.WriteAllText(Path.Combine(dir, "steamclient64.dll"), client);
        return dir;
    }

    [Fact]
    public void Three_signed_files_load_by_full_path_dependencies_first()
    {
        var dir = Folder("good");
        var g = new FakeGuard();
        var r = g.LoadClient(dir);
        r.Ok.Should().BeTrue(r.Detail);
        r.Detail.Should().Be(dir);
        g.LoadedFiles.Should().Equal("tier0_s64.dll", "vstdlib_s64.dll", "steamclient64.dll");
        r.Handle.Should().Be((IntPtr)3, "the handle is steamclient64.dll's");

        var byFile = new FakeGuard().LoadClient(Path.Combine(dir, "steamclient64.dll"));
        byFile.Ok.Should().BeTrue("the setting may name the file");
        byFile.Detail.Should().Be(dir);
    }

    [Fact]
    public void One_file_not_signed_by_Valve_and_nothing_loads()
    {
        foreach (var bad in new[] { "tier0", "vstd", "client" })
        {
            var dir = Folder("unsigned-" + bad, tier0: bad == "tier0" ? "EVIL" : "VALVE t", vstd: bad == "vstd" ? "EVIL" : "VALVE v", client: bad == "client" ? "EVIL" : "VALVE c");
            var g = new FakeGuard();
            var r = g.LoadClient(dir);
            r.Ok.Should().BeFalse();
            r.Detail.Should().Contain("not signed by Valve");
            g.LoadedFiles.Should().BeEmpty("a bad file anywhere stops every load, " + bad);
        }
    }

    [Fact]
    public void Elevated_the_folder_and_each_file_must_be_locked()
    {
        var dir = Folder("rights");
        var open = new FakeGuard { Elevated = true };
        open.Rights[dir] = "BUILTIN\\Users can change it";
        var r = open.LoadClient(dir);
        r.Ok.Should().BeFalse();
        r.Detail.Should().Contain("its folder can be changed by others");
        open.LoadedFiles.Should().BeEmpty();

        var fileOpen = new FakeGuard { Elevated = true };
        fileOpen.Rights[Path.Combine(dir, "vstdlib_s64.dll")] = "S-1-5-21-1 can change it";
        var f = fileOpen.LoadClient(dir);
        f.Ok.Should().BeFalse();
        f.Detail.Should().Contain("vstdlib_s64.dll can be changed by others");
        fileOpen.LoadedFiles.Should().BeEmpty();

        var locked = new FakeGuard { Elevated = true };
        locked.LoadClient(dir).Ok.Should().BeTrue();
        locked.RightsAsked.Should().HaveCount(4, "the folder and the three files");

        var notElevated = new FakeGuard { Elevated = false };
        notElevated.Rights[dir] = "BUILTIN\\Users can change it";
        notElevated.LoadClient(dir).Ok.Should().BeTrue("a process without administrator rights gains nothing from a locked folder");
        notElevated.RightsAsked.Should().BeEmpty();
    }

    [Fact]
    public void A_missing_file_refuses_and_nothing_loads()
    {
        var dir = Folder("missing", tier0: null);
        var g = new FakeGuard();
        var r = g.LoadClient(dir);
        r.Ok.Should().BeFalse();
        r.Detail.Should().Contain("tier0_s64.dll could not be opened");
        g.LoadedFiles.Should().BeEmpty();
    }

    [Fact]
    public void Links_are_never_loaded_through()
    {
        var good = Folder("real");
        // a link in place of one file, pointing at a signed file
        var dir = Folder("filelink", tier0: null);
        File.CreateSymbolicLink(Path.Combine(dir, "tier0_s64.dll"), Path.Combine(good, "tier0_s64.dll"));
        var g = new FakeGuard();
        var r = g.LoadClient(dir);
        r.Ok.Should().BeFalse();
        r.Detail.Should().Contain("tier0_s64.dll is a link");
        g.LoadedFiles.Should().BeEmpty();

        // the configured folder itself a link
        var linkDir = Path.Combine(_root, "dirlink");
        Directory.CreateSymbolicLink(linkDir, good);
        var g2 = new FakeGuard();
        var r2 = g2.LoadClient(linkDir);
        r2.Ok.Should().BeFalse();
        r2.Detail.Should().Contain("its folder is a link");
        g2.LoadedFiles.Should().BeEmpty();

        // a link further up the path: the open file's real path is not the path asked for
        var upper = Path.Combine(_root, "upper");
        Directory.CreateSymbolicLink(upper, _root);
        var g3 = new FakeGuard();
        var r3 = g3.LoadClient(Path.Combine(upper, "real"));
        r3.Ok.Should().BeFalse();
        r3.Detail.Should().Contain("is not reached by its own path");
        g3.LoadedFiles.Should().BeEmpty();
    }

    [Fact]
    public void An_empty_setting_turns_Steam_checks_off_and_nothing_is_searched()
    {
        // signed files right beside HearthServer must not be picked up when the setting is empty
        var beside = Path.Combine(AppContext.BaseDirectory, "steamclient64.dll");
        var made = !File.Exists(beside);
        if (made) File.WriteAllText(beside, "VALVE c");
        try
        {
            foreach (var empty in new[] { "", "   " })
            {
                var g = new FakeGuard();
                g.ClientFolder(empty).Should().BeNull();
                var r = g.LoadClient(empty);
                r.Ok.Should().BeFalse();
                r.Detail.Should().Contain("Identity:SteamClientPath is not set");
                g.LoadedFiles.Should().BeEmpty();
            }
        }
        finally
        {
            if (made) File.Delete(beside);
        }

        // a configured path that is not there is never swapped for another folder
        var good = Folder("only-configured");
        var g3 = new FakeGuard();
        g3.LoadClient(Path.Combine(_root, "gone")).Ok.Should().BeFalse();
        g3.LoadedFiles.Should().BeEmpty();
        // a configured file must be named steamclient64.dll
        var renamed = Path.Combine(good, "other.dll");
        File.WriteAllText(renamed, "VALVE x");
        g3.LoadClient(renamed).Ok.Should().BeFalse();
        // and the configured folder still works
        new FakeGuard().LoadClient(good).Ok.Should().BeTrue();
    }

    [Fact]
    public async Task An_empty_setting_reaches_the_verifier_as_Steam_checks_off()
    {
        var api = Path.Combine(_root, "steam_api64.dll");
        File.WriteAllText(api, "VALVE api");
        var options = Options.Create(new HearthServerOptions { Identity = new IdentityOptions { SteamApiPath = api, SteamClientPath = "" } });
        var guard = new FakeGuard();
        using var verifier = new SteamGameServerTicketVerifier(options, NullLogger<SteamGameServerTicketVerifier>.Instance, guard);
        var result = await verifier.VerifyAsync("76561199000000201", new byte[32], CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
        result.Outcome.Should().Be(SteamTicketOutcome.Unavailable);
        result.Detail.Should().Contain("Identity:SteamClientPath is not set");
        guard.LoadedFiles.Should().BeEmpty();
    }

    [Fact]
    public void The_Steam_API_library_is_checked_and_no_client_library_may_sit_beside_it()
    {
        var client = Folder("api-client");
        var game = Path.Combine(_root, "game", "Win64");
        Directory.CreateDirectory(game);
        var api = Path.Combine(game, "steam_api64.dll");
        File.WriteAllText(api, "VALVE api");

        var g = new FakeGuard();
        var ok = g.LoadApi(api, client);
        ok.Ok.Should().BeTrue(ok.Detail);
        g.SystemImportLoads.Should().Equal("steam_api64.dll");
        g.LoadedFiles.Should().BeEmpty("the Steam API library's imports come from System32 only");

        File.WriteAllText(api, "EVIL api");
        var unsigned = new FakeGuard().LoadApi(api, client);
        unsigned.Ok.Should().BeFalse();
        unsigned.Detail.Should().Contain("not signed by Valve");

        File.WriteAllText(api, "VALVE api");
        File.WriteAllText(Path.Combine(game, "steamclient64.dll"), "VALVE planted");
        var beside = new FakeGuard();
        var r = beside.LoadApi(api, client);
        r.Ok.Should().BeFalse();
        r.Detail.Should().Contain("steamclient64.dll sits beside the Steam API library");
        beside.LoadedFiles.Should().BeEmpty();
        beside.SystemImportLoads.Should().BeEmpty();

        // the game's folder reached through a link (a server folder kept on another drive) still works for the API library
        File.Delete(Path.Combine(game, "steamclient64.dll"));
        var gameLink = Path.Combine(_root, "game-link");
        Directory.CreateSymbolicLink(gameLink, Path.Combine(_root, "game"));
        new FakeGuard().LoadApi(Path.Combine(gameLink, "Win64", "steam_api64.dll"), client).Ok.Should().BeTrue("the real-path check is for the client files only");
        // ...but the API library file itself a link is refused
        File.Move(api, api + ".real");
        File.CreateSymbolicLink(api, api + ".real");
        new FakeGuard().LoadApi(api, client).Detail.Should().Contain("is a link");
        File.Delete(api);
        File.Move(api + ".real", api);

        // the client files and the Steam API library in one checked folder is fine
        File.WriteAllText(Path.Combine(client, "steam_api64.dll"), "VALVE api");
        new FakeGuard().LoadApi(Path.Combine(client, "steam_api64.dll"), client).Ok.Should().BeTrue();
    }

    [Fact]
    public void The_Steam_API_library_loads_with_System32_imports_only_and_the_client_files_as_before()
    {
        // Security 2026-11-16: a full-path load lets Windows look for the library's own imports in its folder first, and
        // the game folder beside steam_api64.dll may be writable by the game's owner. The client files' folder is locked.
        var client = Folder("sys-client");
        var game = Path.Combine(_root, "sys-game");
        Directory.CreateDirectory(game);
        var api = Path.Combine(game, "steam_api64.dll");
        File.WriteAllText(api, "VALVE api");

        var g = new FakeGuard();
        g.LoadClient(client).Ok.Should().BeTrue();
        g.LoadApi(api, client).Ok.Should().BeTrue();

        g.LoadedFiles.Should().Equal("tier0_s64.dll", "vstdlib_s64.dll", "steamclient64.dll");
        g.SystemImportLoads.Should().Equal("steam_api64.dll");
        SteamLibraryGuard.LoadLibrarySearchSystem32.Should().Be(0x00000800u, "LOAD_LIBRARY_SEARCH_SYSTEM32");
    }

    [Fact]
    public void The_signer_must_be_exactly_Valve_Corp()
    {
        SteamLibraryGuard.SignerIsValve(new X500DistinguishedName("CN=Valve Corp., O=Valve Corp., L=Bellevue, S=Washington, C=US")).Should().BeTrue();
        SteamLibraryGuard.SignerIsValve(new X500DistinguishedName("CN=Valve Corp. Ltd, O=Valve Corp.")).Should().BeFalse();
        SteamLibraryGuard.SignerIsValve(new X500DistinguishedName("CN=Valve Corp.")).Should().BeFalse();
        SteamLibraryGuard.SignerIsValve(new X500DistinguishedName("CN=Mallory, OU=CN=Valve Corp., O=Valve Corp.")).Should().BeFalse();
        SteamLibraryGuard.SignerIsValve(new X500DistinguishedName("CN=Valve Corp., CN=Other, O=Valve Corp.")).Should().BeFalse();
    }

    [Fact]
    public async Task A_refused_client_library_turns_Steam_checks_off_with_the_reason()
    {
        var api = Path.Combine(_root, "steam_api64.dll");
        File.WriteAllText(api, "VALVE api");
        var dir = Folder("verifier", client: "EVIL");
        var options = Options.Create(new HearthServerOptions { Identity = new IdentityOptions { SteamApiPath = api, SteamClientPath = dir } });
        var guard = new FakeGuard();
        using var verifier = new SteamGameServerTicketVerifier(options, NullLogger<SteamGameServerTicketVerifier>.Instance, guard);
        var result = await verifier.VerifyAsync("76561199000000201", new byte[32], CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
        result.Outcome.Should().Be(SteamTicketOutcome.Unavailable);
        result.Detail.Should().Contain("Steam client library refused").And.Contain("not signed by Valve");
        guard.LoadedFiles.Should().BeEmpty("nothing loads, and there is no search by name to fall back on");
    }

    // ------------ the real Windows checks (they only mean anything on Windows; CI runs them there)

    [Fact]
    public void Windows_held_files_cannot_be_changed_or_removed_between_the_check_and_the_load()
    {
        if (!OperatingSystem.IsWindows()) return;
        var dir = Folder("held");
        var tried = new List<string>();
        var g = new FakeGuard
        {
            DuringSignature = path =>
            {
                try { File.WriteAllText(path, "EVIL"); tried.Add("written"); } catch (IOException) { }
                try { File.Move(path, path + ".old"); tried.Add("moved"); } catch (IOException) { }
                try { File.Delete(path); tried.Add("deleted"); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                try { Directory.Move(dir, dir + "-moved"); tried.Add("folder moved"); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            },
        };
        g.LoadClient(dir).Ok.Should().BeTrue();
        tried.Should().BeEmpty();
    }

    [Fact]
    public void Windows_real_checks_refuse_an_unsigned_file_and_a_folder_the_user_owns()
    {
        if (!OperatingSystem.IsWindows()) return;
        var dir = Folder("real-checks", tier0: "not a signed library", vstd: "x", client: "x");
        var g = new SteamLibraryGuard();
        var file = Path.Combine(dir, "tier0_s64.dll");
        using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            g.SignatureProblem(file, fs.SafeFileHandle).Should().StartWith("no valid signature");
            SteamLibraryGuard.SamePath(g.RealPath(fs.SafeFileHandle)!, file).Should().BeTrue();
        }
        if (!g.IsElevated) g.RightsProblem(dir, isFolder: true).Should().NotBeNull("a temp folder the test's own account owns is not locked");
        var r = g.CheckAndLoad(dir, SteamLibraryGuard.ClientFiles.Select(f => Path.Combine(dir, f)).ToList(), lockedFolder: false, exactPath: true);
        r.Ok.Should().BeFalse();
        r.Detail.Should().Contain("no valid signature");
    }

    // A real library whose import sits, as a bad file, beside it: the Steam API library's load must take that import
    // from System32. Before 2026-11-16 the full-path load looked beside it first and failed on the planted file.
    private sealed class SignedByValveForTheTest : SteamLibraryGuard
    {
        public override bool IsElevated => false;
        public override string? SignatureProblem(string path, SafeFileHandle open) => null;
    }

    [Fact]
    public void Windows_the_Steam_API_library_never_takes_an_import_from_its_own_folder()
    {
        if (!OperatingSystem.IsWindows()) return;
        var pair = WindowsLibraryWithAPlainSystemImport();
        pair.Should().NotBeNull("System32 has libraries that import another, unloaded, non-KnownDLLs library");
        var (library, import) = pair!.Value;

        var game = Path.Combine(_root, "planted-import");
        Directory.CreateDirectory(game);
        var copy = Path.Combine(game, Path.GetFileName(library));
        File.Copy(library, copy);
        File.WriteAllText(Path.Combine(game, import), "not a library: planted beside the Steam API library");
        var client = Folder("planted-import-client");

        var r = new SignedByValveForTheTest().LoadApi(copy, client);
        try
        {
            r.Ok.Should().BeTrue($"{Path.GetFileName(library)} imports {import}, which must come from System32: {r.Detail}");
        }
        finally
        {
            if (r.Handle != IntPtr.Zero) System.Runtime.InteropServices.NativeLibrary.Free(r.Handle);
        }
    }

    // A System32 library that imports another System32 library which is not a KnownDLL, not an API set and not already
    // loaded in this process, so where Windows looks for it decides which file loads.
    private static (string Library, string Import)? WindowsLibraryWithAPlainSystemImport()
    {
        if (!OperatingSystem.IsWindows()) return null;
        var sys = Environment.SystemDirectory;
        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs"))
            if (key is not null)
                foreach (var name in key.GetValueNames())
                    if (key.GetValue(name) is string v) known.Add(v);
        var loaded = new HashSet<string>(System.Diagnostics.Process.GetCurrentProcess().Modules
            .Cast<System.Diagnostics.ProcessModule>().Select(m => m.ModuleName), StringComparer.OrdinalIgnoreCase);
        string[] preferred = ["winhttp.dll", "wininet.dll", "dbghelp.dll", "netapi32.dll", "mpr.dll", "wtsapi32.dll", "dhcpcsvc.dll", "credui.dll", "winmm.dll", "version.dll"];
        var candidates = preferred.Select(n => Path.Combine(sys, n))
            .Concat(Directory.EnumerateFiles(sys, "*.dll").OrderBy(f => f, StringComparer.OrdinalIgnoreCase).Take(400));
        foreach (var library in candidates)
        {
            if (!File.Exists(library) || loaded.Contains(Path.GetFileName(library)) || new FileInfo(library).Length > 4_000_000) continue;
            List<string> imports;
            try { imports = PeImports(library); } catch { continue; }
            foreach (var import in imports)
            {
                if (import.StartsWith("api-ms-", StringComparison.OrdinalIgnoreCase) || import.StartsWith("ext-ms-", StringComparison.OrdinalIgnoreCase)) continue;
                if (known.Contains(import) || loaded.Contains(import) || !File.Exists(Path.Combine(sys, import))) continue;
                return (library, import);
            }
        }
        return null;
    }

    // The names in a PE file's import table (not its delay-load table).
    private static List<string> PeImports(string path)
    {
        var d = File.ReadAllBytes(path);
        int pe = BitConverter.ToInt32(d, 0x3C);
        int sections = BitConverter.ToUInt16(d, pe + 6), optSize = BitConverter.ToUInt16(d, pe + 20), opt = pe + 24;
        bool pe64 = BitConverter.ToUInt16(d, opt) == 0x20B;
        int importRva = BitConverter.ToInt32(d, opt + (pe64 ? 112 : 96) + 8);
        int Offset(int rva)
        {
            for (var i = 0; i < sections; i++)
            {
                int o = opt + optSize + i * 40;
                int vsize = BitConverter.ToInt32(d, o + 8), va = BitConverter.ToInt32(d, o + 12), rawSize = BitConverter.ToInt32(d, o + 16), raw = BitConverter.ToInt32(d, o + 20);
                if (rva >= va && rva < va + Math.Max(vsize, rawSize)) return rva - va + raw;
            }
            throw new InvalidDataException("rva outside the sections");
        }
        var names = new List<string>();
        if (importRva == 0) return names;
        for (int o = Offset(importRva); ; o += 20)
        {
            int nameRva = BitConverter.ToInt32(d, o + 12);
            if (nameRva == 0) break;
            int s = Offset(nameRva), e = Array.IndexOf(d, (byte)0, s);
            names.Add(System.Text.Encoding.ASCII.GetString(d, s, e - s));
        }
        return names;
    }
}
