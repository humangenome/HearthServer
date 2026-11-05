// HearthIdentity: a returning player's character follows their Steam account instead of their computer.
//
// Bellwright keys a player's character on the engine's offline id, "<computer name>-<32 hex machine id>"
// (AMistOasisGameMode::InitNewPlayer hashes FUniqueNetIdWrapper::ToString with MD5 into the persistence GUID, and the
// player record stores the id string itself). A new or renamed computer therefore starts a new character, and the old
// one waits in the world (found 2026-10-27).
//
// This module hooks AMistOasisGameMode::PreLogin, which receives the join options and the connection's own player id
// before anything is keyed. When the options carry a HearthIdToken that HearthServer signed for the join's ?PlayerId
// (HearthServer checks the player's Steam session ticket before it signs; tokens live 10 minutes and work once), and
// HearthServer's map has a first computer id for that Steam ID, the connection's id is rebuilt from that first id with
// the engine's own FUniqueNetIdRepl::UniqueIdFromString. Login, InitNewPlayer, the save record and the save guard then
// all see the first computer's id, so the player gets their first character back. No token, a bad token, or no map
// entry: nothing changes. A failure inside the hook never blocks a join.
//
// Files (HearthServer owns both): <root>\HearthServer\data\identity\token.key (64 hex = the 32-byte HMAC key) and
// <root>\HearthServer\data\identity\steam-map.tsv ("steam64<TAB>first computer id" lines). Log: <Logs>\bw_identity.log,
// never the token. Build-locked to Bellwright 24840601 (SizeOfImage plus the prologue of every function it calls or
// hooks); on any other build it installs nothing and says so.
#include <windows.h>

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <map>
#include <set>
#include <string>

#include "IdentityCore.hpp"

namespace
{
constexpr wchar_t kGameModule[] = L"BellwrightGame-Win64-Shipping.exe";
constexpr std::uintptr_t kExpectedImageSize = 0x0ce02000;

// ---- game functions (build 24840601, from the game's PDB; RVA = .text offset + 0x1000) --------------------------
constexpr std::uintptr_t kRvaPreLogin = 0x064A6F60;           // AMistOasisGameMode::PreLogin (hooked)
constexpr std::uintptr_t kRvaUniqueIdFromString = 0x03F54A30; // FUniqueNetIdRepl::UniqueIdFromString(FName, const FString&)
constexpr std::uintptr_t kRvaFNameCtor = 0x013BB710;          // FName::FName(const TCHAR*, EFindName)

constexpr unsigned char kPreLoginPrologue[16] = {
    0x40, 0x53,                   // push rbx
    0x56,                         // push rsi
    0x57,                         // push rdi
    0x48, 0x83, 0xEC, 0x40,       // sub rsp, 40h
    0x48, 0x8B, 0x01,             // mov rax, [rcx]
    0x48, 0x89, 0x6C, 0x24, 0x60, // mov [rsp+60h], rbp
};
constexpr unsigned char kUniqueIdFromStringPrologue[10] = {0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x20};
constexpr unsigned char kFNameCtorPrologue[10] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x30};

// UE5 FString = TArray<TCHAR>: data pointer, count including the terminating zero, capacity.
struct FStringRaw
{
    wchar_t* data;
    std::int32_t num;
    std::int32_t max;
};

using PreLoginFn = void (*)(void* self, const FStringRaw* options, const FStringRaw* address, void* uniqueId,
    FStringRaw* errorMessage);
using UniqueIdFromStringFn = void (*)(void* repl, std::uint64_t typeName, const FStringRaw* contents);
using FNameCtorFn = void* (*)(void* name, const wchar_t* text, int findType);

std::uintptr_t g_base = 0;
PreLoginFn g_originalPreLogin = nullptr;
UniqueIdFromStringFn g_uniqueIdFromString = nullptr;
FNameCtorFn g_fnameCtor = nullptr;
bool g_installTried = false;
bool g_installed = false;
std::wstring g_logPath;
std::wstring g_keyPath;
std::wstring g_mapPath;
std::string g_key;
std::map<std::string, std::string> g_map;
FILETIME g_keyTime{};
FILETIME g_mapTime{};
std::set<std::string> g_usedNonces;
unsigned long long g_joins = 0, g_swaps = 0;

std::wstring EnvOr(const wchar_t* name, const std::wstring& fallback)
{
    wchar_t buf[1024];
    const DWORD n = GetEnvironmentVariableW(name, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
    if (n == 0 || n >= sizeof(buf) / sizeof(buf[0])) return fallback;
    return std::wstring(buf, n);
}

std::wstring ParentDir(const std::wstring& path)
{
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"" : path.substr(0, slash);
}

void ResolvePaths()
{
    if (!g_logPath.empty()) return;
    const std::wstring hostLog = EnvOr(L"HEARTH_HOST_LOG", EnvOr(L"BW_HOST_LOG", L""));
    const std::wstring logs = ParentDir(hostLog);
    if (logs.empty())
    {
        g_logPath = L"bw_identity.log";
        return;
    }
    g_logPath = logs + L"\\bw_identity.log";
    const std::wstring root = ParentDir(logs);
    g_keyPath = root + L"\\HearthServer\\data\\identity\\token.key";
    g_mapPath = root + L"\\HearthServer\\data\\identity\\steam-map.tsv";
}

void Log(const char* format, ...)
{
    ResolvePaths();
    char message[700];
    va_list args;
    va_start(args, format);
    std::vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    SYSTEMTIME now{};
    GetLocalTime(&now);
    char line[800];
    const int len = std::snprintf(line, sizeof(line), "%02u:%02u:%02u [bw_identity] %s\r\n", now.wHour, now.wMinute,
        now.wSecond, message);
    if (len <= 0) return;
    HANDLE file = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(len < static_cast<int>(sizeof(line)) ? len : sizeof(line) - 1), &written, nullptr);
    CloseHandle(file);
}

bool IsReadable(const void* p, std::size_t n)
{
    MEMORY_BASIC_INFORMATION info{};
    if (!VirtualQuery(p, &info, sizeof(info)) || info.State != MEM_COMMIT) return false;
    if (info.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return false;
    const auto end = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
    return reinterpret_cast<std::uintptr_t>(p) + n <= end;
}

bool ReadModuleBase()
{
    HMODULE module = GetModuleHandleW(kGameModule);
    if (!module) return false;
    const auto base = reinterpret_cast<std::uintptr_t>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (!IsReadable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (!IsReadable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE) return false;
    if (nt->OptionalHeader.SizeOfImage != kExpectedImageSize) return false;
    g_base = base;
    return true;
}

bool PrologueMatches(std::uintptr_t rva, const unsigned char* expected, std::size_t n)
{
    const auto* at = reinterpret_cast<const unsigned char*>(g_base + rva);
    return IsReadable(at, n) && std::memcmp(at, expected, n) == 0;
}

void WriteAbsoluteJump(unsigned char* at, const void* target)
{
    at[0] = 0xFF;
    at[1] = 0x25;
    at[2] = at[3] = at[4] = at[5] = 0x00;
    std::memcpy(at + 6, &target, sizeof(target));
}

// ---- HearthServer's files ------------------------------------------------------------------------------------------
bool ReadSmallFile(const std::wstring& path, std::string& out, FILETIME& seen, bool& changed)
{
    changed = false;
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (path.empty() || !GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return false;
    if (CompareFileTime(&attr.ftLastWriteTime, &seen) == 0) return true;
    if (attr.nFileSizeHigh != 0 || attr.nFileSizeLow > 4 * 1024 * 1024) return false;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    std::string data(attr.nFileSizeLow, '\0');
    DWORD read = 0;
    const BOOL ok = ReadFile(file, data.data(), attr.nFileSizeLow, &read, nullptr);
    CloseHandle(file);
    if (!ok) return false;
    data.resize(read);
    out.swap(data);
    seen = attr.ftLastWriteTime;
    changed = true;
    return true;
}

void RefreshServerFiles()
{
    std::string text;
    bool changed = false;
    if (ReadSmallFile(g_keyPath, text, g_keyTime, changed) && changed)
    {
        while (!text.empty() && (text.back() == '\r' || text.back() == '\n' || text.back() == ' ')) text.pop_back();
        std::string raw;
        if (text.size() == 64 && hearth::identity::HexDecode(text, raw)) g_key = raw;
        else { g_key.clear(); Log("token key unreadable (expected 64 hex)"); }
    }
    if (ReadSmallFile(g_mapPath, text, g_mapTime, changed) && changed)
    {
        int skipped = 0;
        g_map = hearth::identity::ParseSteamMap(text, &skipped);
        Log("steam map loaded: %u players, %d bad lines skipped", static_cast<unsigned>(g_map.size()), skipped);
    }
}

std::string Narrow(const FStringRaw* s)
{
    if (!s || !s->data || s->num <= 0 || s->num > 8192 || !IsReadable(s->data, static_cast<std::size_t>(s->num) * 2)) return "";
    std::string out;
    out.reserve(static_cast<std::size_t>(s->num));
    for (int i = 0; i < s->num && s->data[i] != 0; ++i)
    {
        const wchar_t c = s->data[i];
        out.push_back(c < 128 ? static_cast<char>(c) : '?');
    }
    return out;
}

// "<computer name>-<last 4 of the machine id>" for the log; anything else is cut to 12 characters.
std::string Short(const std::string& id)
{
    if (hearth::identity::IsComputerId(id)) return id.substr(0, id.size() - 33) + "-..." + id.substr(id.size() - 4);
    return id.substr(0, 12);
}

// ---- the hook ------------------------------------------------------------------------------------------------------
void HookPreLogin(void* self, const FStringRaw* options, const FStringRaw* address, void* uniqueId, FStringRaw* errorMessage)
{
    try
    {
        ++g_joins;
        RefreshServerFiles();
        const std::string opts = Narrow(options);
        const auto d = hearth::identity::Decide(opts, g_key, g_map, static_cast<std::int64_t>(std::time(nullptr)), g_usedNonces);
        if (!d.nonce.empty()) g_usedNonces.insert(d.nonce);
        const std::string steam = hearth::identity::OptionValue(opts, "PlayerId");
        const std::string steamTail = steam.size() > 4 ? steam.substr(steam.size() - 4) : steam;
        if (d.swap && uniqueId && g_uniqueIdFromString && g_fnameCtor)
        {
            std::wstring wide(d.to.begin(), d.to.end());
            FStringRaw contents{wide.data(), static_cast<std::int32_t>(wide.size() + 1), static_cast<std::int32_t>(wide.size() + 1)};
            alignas(8) unsigned char nameBuf[16] = {};
            g_fnameCtor(nameBuf, L"NULL", 1 /* FNAME_Add */);
            std::uint64_t nameBits = 0;
            std::memcpy(&nameBits, nameBuf, sizeof(nameBits));
            g_uniqueIdFromString(uniqueId, nameBits, &contents);
            ++g_swaps;
            Log("join steam ...%s from %s: %s -> %s", steamTail.c_str(), Short(hearth::identity::OptionValue(opts, "Name")).c_str(),
                d.reason.c_str(), Short(d.to).c_str());
        }
        else
        {
            Log("join steam ...%s: %s", steamTail.c_str(), d.reason.c_str());
        }
    }
    catch (...)
    {
        Log("identity check failed inside the join (join goes on unchanged)");
    }
    g_originalPreLogin(self, options, address, uniqueId, errorMessage);
}

void Install()
{
    g_installTried = true;
    ResolvePaths();
    if (!ReadModuleBase())
    {
        Log("install refused: not Bellwright build 24840601 (module or SizeOfImage differs)");
        return;
    }
    if (!PrologueMatches(kRvaPreLogin, kPreLoginPrologue, sizeof(kPreLoginPrologue)) ||
        !PrologueMatches(kRvaUniqueIdFromString, kUniqueIdFromStringPrologue, sizeof(kUniqueIdFromStringPrologue)) ||
        !PrologueMatches(kRvaFNameCtor, kFNameCtorPrologue, sizeof(kFNameCtorPrologue)))
    {
        Log("install refused: a prologue does not match build 24840601");
        return;
    }
    g_uniqueIdFromString = reinterpret_cast<UniqueIdFromStringFn>(g_base + kRvaUniqueIdFromString);
    g_fnameCtor = reinterpret_cast<FNameCtorFn>(g_base + kRvaFNameCtor);
    auto* target = reinterpret_cast<unsigned char*>(g_base + kRvaPreLogin);
    auto* trampoline = static_cast<unsigned char*>(VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!trampoline)
    {
        Log("install refused: no memory for the trampoline");
        return;
    }
    // the stolen 16 bytes are position independent (see kPreLoginPrologue)
    std::memcpy(trampoline, target, sizeof(kPreLoginPrologue));
    WriteAbsoluteJump(trampoline + sizeof(kPreLoginPrologue), target + sizeof(kPreLoginPrologue));
    FlushInstructionCache(GetCurrentProcess(), trampoline, 64);
    DWORD oldProtect = 0;
    if (!VirtualProtect(target, sizeof(kPreLoginPrologue), PAGE_EXECUTE_READWRITE, &oldProtect))
    {
        Log("install failed: cannot unprotect PreLogin");
        return;
    }
    g_originalPreLogin = reinterpret_cast<PreLoginFn>(trampoline);
    unsigned char patch[sizeof(kPreLoginPrologue)];
    std::memset(patch, 0x90, sizeof(patch));
    WriteAbsoluteJump(patch, reinterpret_cast<const void*>(&HookPreLogin));
    std::memcpy(target, patch, sizeof(patch));
    DWORD ignored = 0;
    VirtualProtect(target, sizeof(kPreLoginPrologue), oldProtect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof(kPreLoginPrologue));
    g_installed = true;
    RefreshServerFiles();
    Log("installed: PreLogin hooked; token key %s; steam map %u players", g_key.empty() ? "MISSING (no swaps)" : "loaded",
        static_cast<unsigned>(g_map.size()));
}
} // namespace

// Called by the bw_ident Lua mod on the game thread (a lua_CFunction returning 0 results). The first call installs;
// later calls log one status line every 10 minutes.
extern "C" __declspec(dllexport) int HearthIdentity_Service(void*)
{
    static ULONGLONG lastStatus = 0;
    if (!g_installTried) Install();
    const ULONGLONG now = GetTickCount64();
    if (g_installed && now - lastStatus >= 600000)
    {
        lastStatus = now;
        Log("status: joins=%llu swaps=%llu map=%u key=%s", g_joins, g_swaps, static_cast<unsigned>(g_map.size()),
            g_key.empty() ? "missing" : "ok");
    }
    return 0;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}
