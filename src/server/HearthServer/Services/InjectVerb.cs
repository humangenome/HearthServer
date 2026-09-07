using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace HearthServer.Services;

// Compiled host-side injection verb. Replaces an earlier inline PowerShell
// `Add-Type` helper used by the host launch template. Host-side DLL injection
// must live in compiled .NET rather than inline PowerShell reflection, because
// directory exclusions do not suppress script scanning of inline reflection.
//
// Invoked as:
//   HearthServer.exe inject --pid <pid> --dll <ue4ss_dll_path>
//   HearthServer.exe inject --pid <pid> --patch-tickworldtravel [<rva-hex>]
//   HearthServer.exe inject --pid <pid> --dll <path> --patch-tickworldtravel <rva-hex>
//
// Behavior + reporting are kept byte-for-byte compatible with the previous
// helper so existing log parsing keeps working:
//   * The DLL inject prints "OK inject rc=0 ..." on success or
//     "ERR inject rc=<n> ..." on failure (rc uses the same -1..-5 codes).
//   * The TickWorldTravel patch prints the SAME "OK ..." / "ERR ..." string the
//     previous patch helper returned, so the caller's StartsWith('OK') gate is
//     unchanged.
// Exit code: 0 when every requested step succeeded, 1 otherwise — so the caller
// can branch on $LASTEXITCODE as well as parse the line.
internal static class InjectVerb
{
    // Default RVA for UEngine::TickWorldTravel in BellwrightGame-Win64-Shipping.exe
    // (UE5.7.4 build 24840601 / HearthServer v0.1.89). The caller SHOULD pass the
    // RVA explicitly (--patch-tickworldtravel <hex>) so a new game build only needs
    // a pin bump, never a server recompile; this default exists only as a fallback.
    private const long DefaultTickWorldTravelRva = 0x4485B20;

    // UEngine::TickWorldTravel function prologue we expect to overwrite, and the
    // ret-stub we replace it with (C3 = ret, then NOP padding).
    private static readonly byte[] ExpectedPrologue =
    {
        0x40, 0x55, 0x56, 0x57, 0x48, 0x8D, 0x6C, 0x24, 0xB9,
        0x48, 0x81, 0xEC, 0xE0, 0x00, 0x00, 0x00, 0x48, 0x8B, 0xF1,
    };

    private static readonly byte[] RetStub = { 0xC3, 0x90, 0x90, 0x90, 0x90 };

    // Process-access mask used by the old BwInj (PROCESS_ALL_ACCESS = 0x1FFFFF).
    private const uint PROCESS_ALL_ACCESS = 0x1FFFFF;
    private const uint MEM_COMMIT_RESERVE = 0x3000; // MEM_COMMIT | MEM_RESERVE
    private const uint PAGE_READWRITE = 0x04;
    private const uint PAGE_EXECUTE_READWRITE = 0x40;

    // Entry point dispatched from Program.Main when argv[0] == "inject".
    // Callable from any platform — runtime-guards then delegates the Windows-only
    // P/Invoke work to RunWindows. Returns the process exit code (0/1).
    public static int Run(string[] args)
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            Console.Error.WriteLine("ERR inject verb is Windows-only");
            return 1;
        }
        return RunWindows(args);
    }

    [SupportedOSPlatform("windows")]
    private static int RunWindows(string[] args)
    {
        int pid = 0;
        string? dll = null;
        bool doPatch = false;
        long patchRva = DefaultTickWorldTravelRva;

        // Parse the inject verb's flags (args[0] is "inject", start at 1).
        for (var i = 1; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "--pid":
                    if (++i >= args.Length || !int.TryParse(args[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out pid))
                    {
                        Console.Error.WriteLine("ERR --pid requires an integer process id");
                        return 1;
                    }
                    break;
                case "--dll":
                    if (++i >= args.Length)
                    {
                        Console.Error.WriteLine("ERR --dll requires a path");
                        return 1;
                    }
                    dll = args[i];
                    break;
                case "--patch-tickworldtravel":
                    doPatch = true;
                    // Optional inline RVA (hex, with or without 0x). If the next token
                    // looks like another flag, fall back to the default RVA.
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                    {
                        var rvaTok = args[++i];
                        if (!TryParseRva(rvaTok, out patchRva))
                        {
                            Console.Error.WriteLine($"ERR --patch-tickworldtravel got non-hex RVA '{rvaTok}'");
                            return 1;
                        }
                    }
                    break;
                default:
                    Console.Error.WriteLine($"ERR unknown inject flag '{a}'");
                    return 1;
            }
        }

        if (pid <= 0)
        {
            Console.Error.WriteLine("ERR inject requires --pid <pid>");
            return 1;
        }
        if (dll is null && !doPatch)
        {
            Console.Error.WriteLine("ERR inject requires --dll <path> and/or --patch-tickworldtravel [<rva>]");
            return 1;
        }

        var ok = true;

        // 1. DLL injection (UE4SS) — mirrors BwInj::Do, same rc semantics.
        if (dll is not null)
        {
            var rc = InjectDll(pid, dll);
            if (rc == 0)
            {
                Console.WriteLine($"OK inject rc=0 pid={pid} dll={dll}");
            }
            else
            {
                Console.WriteLine($"ERR inject rc={rc} pid={pid} dll={dll}");
                ok = false;
            }
        }

        // 2. TickWorldTravel ret-stub patch — mirrors BwInj::PatchTickWorldTravel,
        //    returns the SAME OK/ERR string the caller already logs + gates on.
        if (doPatch)
        {
            if (!TryGetMainModuleBase(pid, out var imageBase, out var baseErr))
            {
                Console.WriteLine($"ERR {baseErr}");
                ok = false;
            }
            else
            {
                var res = PatchTickWorldTravel(pid, imageBase, patchRva);
                Console.WriteLine(res);
                if (!res.StartsWith("OK", StringComparison.Ordinal)) ok = false;
            }
        }

        return ok ? 0 : 1;
    }

    // Accepts "0x4486B70", "4486B70" (hex assumed for this flag), and plain decimal
    // if explicitly prefixed with "d:". Default is hex (matches the literal in code).
    private static bool TryParseRva(string tok, out long rva)
    {
        rva = 0;
        if (string.IsNullOrWhiteSpace(tok)) return false;
        tok = tok.Trim();
        if (tok.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            tok = tok[2..];
        return long.TryParse(tok, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out rva);
    }

    // CreateRemoteThread(LoadLibraryW) DLL injection. Returns the same rc codes the
    // old BwInj::Do used so existing log lines/diagnostics keep their meaning:
    //   0  success
    //  -1  OpenProcess failed
    //  -2  VirtualAllocEx failed
    //  -3  WriteProcessMemory failed
    //  -4  GetProcAddress(LoadLibraryW) failed
    //  -5  CreateRemoteThread failed
    private static int InjectDll(int pid, string dll)
    {
        var h = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
        if (h == IntPtr.Zero) return -1;
        try
        {
            // LoadLibraryW needs a NUL-terminated wide (UTF-16) path. Encoding.Unicode
            // is UTF-16LE; the trailing "\0" becomes the 2-byte wide terminator.
            var b = Encoding.Unicode.GetBytes(dll + "\0");
            var m = VirtualAllocEx(h, IntPtr.Zero, (uint)b.Length, MEM_COMMIT_RESERVE, PAGE_READWRITE);
            if (m == IntPtr.Zero) return -2;
            if (!WriteProcessMemory(h, m, b, (uint)b.Length, out _)) return -3;
            var ll = GetProcAddress(GetModuleHandle("kernel32"), "LoadLibraryW");
            if (ll == IntPtr.Zero) return -4;
            var t = CreateRemoteThread(h, IntPtr.Zero, 0, ll, m, 0, IntPtr.Zero);
            if (t == IntPtr.Zero) return -5;
            CloseHandle(t);
            return 0;
        }
        finally
        {
            CloseHandle(h);
        }
    }

    // Resolve the main module base address (image base) for the target pid. The old
    // PowerShell read $gameProc.MainModule.BaseAddress; do the equivalent here so the
    // caller no longer needs to compute the base before invoking the patch.
    private static bool TryGetMainModuleBase(int pid, out long imageBase, out string err)
    {
        imageBase = 0;
        err = string.Empty;
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById(pid);
            var mm = p.MainModule;
            if (mm is null)
            {
                err = $"could not read MainModule for pid {pid}";
                return false;
            }
            imageBase = mm.BaseAddress.ToInt64();
            return true;
        }
        catch (Exception ex)
        {
            err = $"could not read image base for pid {pid}: {ex.Message}";
            return false;
        }
    }

    // No-GPU stability patch: ret-stub UEngine::TickWorldTravel so the headless WARP
    // host never re-Browses/LoadMaps after the initial listen. Verifies the prologue
    // before patching, then reads back to confirm. Identical OK/ERR strings to BwInj.
    private static string PatchTickWorldTravel(int pid, long imageBase, long rva)
    {
        var rvaHex = "0x" + rva.ToString("X", CultureInfo.InvariantCulture);
        var h = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
        if (h == IntPtr.Zero) return "ERR OpenProcess";
        try
        {
            var addr = new IntPtr(imageBase + rva);
            var cur = new byte[ExpectedPrologue.Length];
            if (!ReadProcessMemory(h, addr, cur, (uint)cur.Length, out _))
                return "ERR ReadProcessMemory";

            // Already patched? (first RetStub.Length bytes match the stub).
            var already = true;
            for (var i = 0; i < RetStub.Length; i++)
            {
                if (cur[i] != RetStub[i]) { already = false; break; }
            }
            if (already)
                return $"OK already patched UEngine::TickWorldTravel RVA {rvaHex}";

            // Refuse to patch an unexpected prologue (wrong RVA / build drift).
            for (var i = 0; i < ExpectedPrologue.Length; i++)
            {
                if (cur[i] != ExpectedPrologue[i])
                    return $"ERR unexpected TickWorldTravel prologue at RVA {rvaHex} got {Hex(cur, ExpectedPrologue.Length)}";
            }

            if (!VirtualProtectEx(h, addr, (uint)RetStub.Length, PAGE_EXECUTE_READWRITE, out var oldProtect))
                return "ERR VirtualProtectEx";
            if (!WriteProcessMemory(h, addr, RetStub, (uint)RetStub.Length, out _))
                return "ERR WriteProcessMemory";
            FlushInstructionCache(h, addr, (uint)RetStub.Length);
            VirtualProtectEx(h, addr, (uint)RetStub.Length, oldProtect, out _);

            var verify = new byte[RetStub.Length];
            if (!ReadProcessMemory(h, addr, verify, (uint)verify.Length, out _))
                return "ERR verify ReadProcessMemory";
            for (var i = 0; i < RetStub.Length; i++)
            {
                if (verify[i] != RetStub[i])
                    return $"ERR verify mismatch got {Hex(verify, verify.Length)}";
            }

            return $"OK patched UEngine::TickWorldTravel RVA {rvaHex}: "
                 + $"{Hex(ExpectedPrologue, RetStub.Length)} -> {Hex(RetStub, RetStub.Length)}";
        }
        finally
        {
            CloseHandle(h);
        }
    }

    private static string Hex(byte[] b, int len)
    {
        var sb = new StringBuilder();
        for (var i = 0; i < len && i < b.Length; i++)
        {
            if (i > 0) sb.Append('-');
            sb.Append(b[i].ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    // ---- P/Invoke (kernel32) — same surface BwInj used ----
    [DllImport("kernel32", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32", SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out UIntPtr lpNumberOfBytesRead);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out UIntPtr lpNumberOfBytesWritten);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool FlushInstructionCache(IntPtr hProcess, IntPtr lpBaseAddress, uint dwSize);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32", SetLastError = true)]
    private static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, uint dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, IntPtr lpThreadId);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
