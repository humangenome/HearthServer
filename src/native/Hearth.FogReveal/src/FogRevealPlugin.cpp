// HearthFogReveal: software map-fog reveal for the headless (-nullrhi) Bellwright host.
//
// Bellwright keeps the authoritative, persisted, replicated map fog as a plain CPU byte
// array on AMapFog (offset 0x420: TArray<uint8>, 2 bytes per pixel, N*N pixels, N =
// FogRenderTargetSize at 0x310).  On a rendering host that array is refilled from a
// render-target readback (AMapFog::UpdateFogRevealTextures); under -nullrhi that path is
// patched out, so nothing ever writes it: the fog a player reveals is thrown away on the
// next join and never saved.  AMistMapFog::SavePersistenceData serialises the array as-is,
// LoadPersistenceData restores it, ServerConfirmStreamingDone -> QueryMapFog (RLE) sends it
// to every joining client, and AMapFog::GetFogAtLocation / UMapTrackerComponent::
// GetFogRevealedFactor read max(byte0, byte1)/255 from it for icon discovery.
//
// This module does the one thing the missing readback did: it stamps revealed discs into
// that array.  The Lua side (bw_fog) resolves pawn positions to fog pixels through the
// game's own BlueprintCallable UMapViewComponent::GetViewCoordinates and writes a request
// file; this DLL validates the actor and writes the bytes.  No game code is called here.
//
// Build-locked to Bellwright 24840601 (SizeOfImage + AMapFog::GetFogAtLocation prologue).
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace
{
constexpr wchar_t kGameModule[] = L"BellwrightGame-Win64-Shipping.exe";
constexpr std::uintptr_t kExpectedImageSize = 0x0ce02000;
// AMapFog::GetFogAtLocation (build 24840601): the reader of the array we write.
constexpr std::uintptr_t kGetFogAtLocationRva = 0x04579150;
constexpr unsigned char kGetFogAtLocationPrologue[16] = {
    0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x40, 0x83};
constexpr std::uintptr_t kFogSizeOffset = 0x310;        // int32 FogRenderTargetSize (N)
constexpr std::uintptr_t kRevealArrayOffset = 0x420;    // TArray<uint8> N*N*2 (persisted, replicated)
constexpr std::uintptr_t kPermanentArrayOffset = 0x430; // TArray<uint8> N*N*4 (readback copy)
constexpr int kMinFogSize = 16;
constexpr int kMaxFogSize = 8192;

struct TArrayView
{
    unsigned char* data;
    std::int32_t num;
    std::int32_t max;
};

struct Stamp
{
    int cx;
    int cy;
    int r;
};

bool IsReadable(const void* address, std::size_t size)
{
    if (!address) return false;
    MEMORY_BASIC_INFORMATION info{};
    const auto* cursor = static_cast<const unsigned char*>(address);
    const auto* end = cursor + size;
    while (cursor < end)
    {
        if (VirtualQuery(cursor, &info, sizeof(info)) == 0) return false;
        if (info.State != MEM_COMMIT) return false;
        const DWORD protect = info.Protect & 0xff;
        if (protect == PAGE_NOACCESS || (info.Protect & PAGE_GUARD)) return false;
        cursor = static_cast<const unsigned char*>(info.BaseAddress) + info.RegionSize;
    }
    return true;
}

bool IsWritable(const void* address, std::size_t size)
{
    if (!address) return false;
    MEMORY_BASIC_INFORMATION info{};
    const auto* cursor = static_cast<const unsigned char*>(address);
    const auto* end = cursor + size;
    while (cursor < end)
    {
        if (VirtualQuery(cursor, &info, sizeof(info)) == 0) return false;
        if (info.State != MEM_COMMIT) return false;
        const DWORD protect = info.Protect & 0xff;
        const bool writable = protect == PAGE_READWRITE || protect == PAGE_WRITECOPY
            || protect == PAGE_EXECUTE_READWRITE || protect == PAGE_EXECUTE_WRITECOPY;
        if (!writable || (info.Protect & PAGE_GUARD)) return false;
        cursor = static_cast<const unsigned char*>(info.BaseAddress) + info.RegionSize;
    }
    return true;
}

bool ReadModuleBase(std::uintptr_t& base)
{
    HMODULE module = GetModuleHandleW(kGameModule);
    if (!module) return false;
    base = reinterpret_cast<std::uintptr_t>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (!IsReadable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (!IsReadable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE) return false;
    if (nt->OptionalHeader.SizeOfImage != kExpectedImageSize) return false;
    const auto* prologue = reinterpret_cast<const unsigned char*>(base + kGetFogAtLocationRva);
    if (!IsReadable(prologue, sizeof(kGetFogAtLocationPrologue))) return false;
    return std::memcmp(prologue, kGetFogAtLocationPrologue, sizeof(kGetFogAtLocationPrologue)) == 0;
}

std::wstring ModuleDirectory()
{
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&ModuleDirectory), &self))
        return L"";
    wchar_t path[MAX_PATH * 2] = {};
    const DWORD len = GetModuleFileNameW(self, path, static_cast<DWORD>(sizeof(path) / sizeof(path[0])));
    if (len == 0 || len >= sizeof(path) / sizeof(path[0])) return L"";
    std::wstring dir(path, len);
    const auto slash = dir.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"" : dir.substr(0, slash);
}

std::wstring EnvOr(const wchar_t* name, const std::wstring& fallback)
{
    wchar_t buffer[MAX_PATH * 2] = {};
    const DWORD len = GetEnvironmentVariableW(name, buffer, static_cast<DWORD>(sizeof(buffer) / sizeof(buffer[0])));
    if (len == 0 || len >= sizeof(buffer) / sizeof(buffer[0])) return fallback;
    return std::wstring(buffer, len);
}

bool WriteStatus(const std::wstring& path, const std::string& body)
{
    const std::wstring temp = path + L".tmp";
    {
        std::ofstream out(temp.c_str(), std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out << body;
        if (!out) return false;
    }
    return MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

bool ReadArray(std::uintptr_t actor, std::uintptr_t offset, TArrayView& view)
{
    const auto* raw = reinterpret_cast<const unsigned char*>(actor + offset);
    if (!IsReadable(raw, 16)) return false;
    std::memcpy(&view.data, raw, sizeof(view.data));
    std::memcpy(&view.num, raw + 8, sizeof(view.num));
    std::memcpy(&view.max, raw + 12, sizeof(view.max));
    return true;
}

// Request file (written by bw_fog main.lua, one request per call):
//   fog=<decimal actor address>
//   size=<N>
//   value=<0-255>
//   stamp=<cx>,<cy>,<radius px>      (repeated)
struct Request
{
    std::uintptr_t fog = 0;
    int size = 0;
    int value = 255;
    int fill = -1;   // test only: overwrite every reveal byte with this value before stamping
    std::vector<Stamp> stamps;
};

bool ParseRequest(const std::wstring& path, Request& request, std::string& error)
{
    std::ifstream in(path.c_str(), std::ios::binary);
    if (!in) { error = "request_missing"; return false; }
    std::string line;
    while (std::getline(in, line))
    {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n' || line.back() == ' ')) line.pop_back();
        if (line.empty()) continue;
        const auto eq = line.find('=');
        if (eq == std::string::npos) { error = "request_syntax"; return false; }
        const std::string key = line.substr(0, eq);
        const std::string value = line.substr(eq + 1);
        if (key == "fog")
        {
            char* end = nullptr;
            const unsigned long long parsed = std::strtoull(value.c_str(), &end, 10);
            if (!end || *end != '\0' || parsed == 0) { error = "request_fog"; return false; }
            request.fog = static_cast<std::uintptr_t>(parsed);
        }
        else if (key == "size") request.size = std::atoi(value.c_str());
        else if (key == "value") request.value = std::atoi(value.c_str());
        else if (key == "fill") request.fill = std::atoi(value.c_str());
        else if (key == "stamp")
        {
            Stamp stamp{};
            if (std::sscanf(value.c_str(), "%d,%d,%d", &stamp.cx, &stamp.cy, &stamp.r) != 3) { error = "request_stamp"; return false; }
            request.stamps.push_back(stamp);
        }
        else { error = "request_key"; return false; }
    }
    if (request.fog == 0 || request.size < kMinFogSize || request.size > kMaxFogSize) { error = "request_fields"; return false; }
    if (request.value < 0 || request.value > 255) { error = "request_value"; return false; }
    return true;
}

// Fill a disc; returns the number of pixels whose stored value rose.
long long StampDisc(unsigned char* data, int n, int bytesPerPixel, int channels, const Stamp& stamp, unsigned char value)
{
    long long changed = 0;
    const int r = std::max(0, std::min(stamp.r, n));
    const long long r2 = static_cast<long long>(r) * r;
    const int y0 = std::max(0, stamp.cy - r);
    const int y1 = std::min(n - 1, stamp.cy + r);
    const int x0 = std::max(0, stamp.cx - r);
    const int x1 = std::min(n - 1, stamp.cx + r);
    for (int y = y0; y <= y1; ++y)
    {
        const long long dy = static_cast<long long>(y) - stamp.cy;
        for (int x = x0; x <= x1; ++x)
        {
            const long long dx = static_cast<long long>(x) - stamp.cx;
            if (dx * dx + dy * dy > r2) continue;
            unsigned char* pixel = data + (static_cast<std::size_t>(y) * n + x) * bytesPerPixel;
            bool rose = false;
            for (int c = 0; c < channels; ++c)
            {
                if (pixel[c] < value) { pixel[c] = value; rose = true; }
            }
            if (rose) ++changed;
        }
    }
    return changed;
}

void Service()
{
    const std::wstring dir = ModuleDirectory();
    const std::wstring requestPath = EnvOr(L"HEARTH_FOG_REVEAL_REQUEST", dir + L"\\fog-reveal-request.txt");
    const std::wstring statusPath = EnvOr(L"HEARTH_FOG_REVEAL_STATUS", dir + L"\\fog-reveal-status.txt");
    if (dir.empty() && statusPath.empty()) return;

    Request request;
    std::string error;
    if (!ParseRequest(requestPath, request, error))
    {
        WriteStatus(statusPath, "state=error\r\nerror=" + error + "\r\n");
        return;
    }
    DeleteFileW(requestPath.c_str());

    std::uintptr_t base = 0;
    if (!ReadModuleBase(base))
    {
        WriteStatus(statusPath, "state=error\r\nerror=build_mismatch\r\n");
        return;
    }
    if (!IsReadable(reinterpret_cast<const void*>(request.fog), kPermanentArrayOffset + 16))
    {
        WriteStatus(statusPath, "state=error\r\nerror=fog_unreadable\r\n");
        return;
    }
    std::uintptr_t vtable = 0;
    std::memcpy(&vtable, reinterpret_cast<const void*>(request.fog), sizeof(vtable));
    if (vtable < base || vtable >= base + kExpectedImageSize)
    {
        WriteStatus(statusPath, "state=error\r\nerror=fog_identity\r\n");
        return;
    }
    std::int32_t fogSize = 0;
    std::memcpy(&fogSize, reinterpret_cast<const void*>(request.fog + kFogSizeOffset), sizeof(fogSize));
    if (fogSize != request.size)
    {
        std::ostringstream body;
        body << "state=error\r\nerror=fog_size\r\nactual=" << fogSize << "\r\n";
        WriteStatus(statusPath, body.str());
        return;
    }
    const long long pixels = static_cast<long long>(fogSize) * fogSize;

    TArrayView reveal{};
    if (!ReadArray(request.fog, kRevealArrayOffset, reveal) || reveal.num != pixels * 2 || reveal.max < reveal.num
        || !IsWritable(reveal.data, static_cast<std::size_t>(reveal.num)))
    {
        std::ostringstream body;
        body << "state=error\r\nerror=reveal_array\r\nnum=" << reveal.num << "\r\nmax=" << reveal.max << "\r\n";
        WriteStatus(statusPath, body.str());
        return;
    }
    TArrayView permanent{};
    const bool permanentUsable = ReadArray(request.fog, kPermanentArrayOffset, permanent)
        && permanent.num == pixels * 4 && permanent.max >= permanent.num
        && IsWritable(permanent.data, static_cast<std::size_t>(permanent.num));

    long long changedReveal = 0;
    long long changedPermanent = 0;
    if (request.fill >= 0 && request.fill <= 255)
    {
        std::memset(reveal.data, request.fill, static_cast<std::size_t>(reveal.num));
        if (permanentUsable) std::memset(permanent.data, request.fill, static_cast<std::size_t>(permanent.num));
    }
    const auto value = static_cast<unsigned char>(request.value);
    for (const Stamp& stamp : request.stamps)
    {
        if (stamp.cx < 0 || stamp.cy < 0 || stamp.cx >= fogSize || stamp.cy >= fogSize || stamp.r < 0) continue;
        changedReveal += StampDisc(reveal.data, fogSize, 2, 2, stamp, value);
        if (permanentUsable) changedPermanent += StampDisc(permanent.data, fogSize, 4, 3, stamp, value);
    }

    long long revealed = 0;
    long long hist0[256] = {};
    long long hist1[256] = {};
    for (long long i = 0; i < pixels; ++i)
    {
        const unsigned char b0 = reveal.data[i * 2];
        const unsigned char b1 = reveal.data[i * 2 + 1];
        ++hist0[b0];
        ++hist1[b1];
        if (b0 || b1) ++revealed;
    }
    std::ostringstream histText;
    for (int channel = 0; channel < 2; ++channel)
    {
        const long long* hist = channel == 0 ? hist0 : hist1;
        histText << "hist" << channel << "=";
        int shown = 0;
        for (int round = 0; round < 6; ++round)
        {
            int best = -1;
            for (int v = 0; v < 256; ++v)
            {
                if (hist[v] == 0) continue;
                if (best < 0 || hist[v] > hist[best]) best = v;
            }
            if (best < 0) break;
            histText << (shown++ ? "," : "") << best << ":" << hist[best];
            const_cast<long long*>(hist)[best] = 0;
        }
        histText << "\r\n";
    }

    std::ostringstream body;
    body << "state=ok\r\nsize=" << fogSize << "\r\nstamps=" << request.stamps.size()
         << "\r\nchanged=" << changedReveal << "\r\nchanged_permanent=" << changedPermanent
         << "\r\npermanent=" << (permanentUsable ? 1 : 0) << "\r\nrevealed=" << revealed
         << "\r\npixels=" << pixels << "\r\n" << histText.str();
    WriteStatus(statusPath, body.str());
}
} // namespace

extern "C" __declspec(dllexport) int HearthFogReveal_Service(void*)
{
    Service();
    return 0;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}
