// HearthFourthSeat: world-data feed for Bellwright players the game has no data seat for.
//
// Bellwright sends its world data (settlements, villagers, orders, quests, storage ...) to a
// joining player through UMistDataBrokerComponent.  That broker seats at most
// GetMaxDataBrokerClients() = 3 remote players: a fixed 3-entry client array in the broker
// (this+0x1C0, the next member starts at +0x1D8) and a fixed 3-entry dirty-mask array in
// every UMistData (+0xA8, the next member starts at +0xC0).  The game is built as one
// listening host plus three guests.  A headless host owns the host seat, so a fourth guest
// who is let past the session cap joins the world but is never seated: AddClient finds no
// free entry and returns, the player never gets data or ClientCompleteInitialSync, and its
// loading screen stays up (IsInitialWorldStateReady waits for the broker's initial sync).
//
// Neither array can grow (a fourth entry overwrites a pointer), so this module does not
// touch them.  It serves every unseated player beside the game's three seats, speaking the
// game's own protocol with the game's own functions:
//
//   - what changed: read at the top of the broker's tick, from the broker's dirty list
//     (+0x138) and each object's pending mask (+0xA0), and from the delete list (+0x148).
//     MarkDirtyBit defers to a side set while the broker ticks, so those values are exactly
//     what the game hands its own three seats in that tick.
//   - how it is sent: FMistDataSerializer batches of up to 8 entries through
//     UMistDataBrokerPlayerComponent::ClientUpdateData.  The serializer writes each object
//     from the mask in the entry; the client index byte it carries is not read by any
//     NetSerializeData in this build.
//   - pacing: one burst, then ClientTransmitReady; the client answers ServerTransmitReady,
//     which reaches UMistDataBrokerComponent::MarkTransmitReady.  The game ignores that for
//     an unseated player; the hook here takes it.
//   - the end of the first full pass: ClientCompleteInitialSync, as the game does.
//
// Everything runs on the game thread, inside the game's own calls.  Build-locked to
// Bellwright 24840601 (SizeOfImage plus the prologue of every hooked function); on any
// other build it installs nothing and says so in the log.
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

namespace
{
constexpr wchar_t kGameModule[] = L"BellwrightGame-Win64-Shipping.exe";
constexpr std::uintptr_t kExpectedImageSize = 0x0ce02000;

// ---- game functions (build 24840601) ----------------------------------------------------
constexpr std::uintptr_t kRvaAddClient = 0x063CFBE0;          // UMistDataBrokerComponent::AddClient
constexpr std::uintptr_t kRvaRemoveClient = 0x063D5C00;       // UMistDataBrokerComponent::RemoveClient
constexpr std::uintptr_t kRvaMarkTransmitReady = 0x063D4D00;  // UMistDataBrokerComponent::MarkTransmitReady
constexpr std::uintptr_t kRvaTickComponent = 0x063D90E0;      // UMistDataBrokerComponent::TickComponent
constexpr std::uintptr_t kRvaSerializerCtor = 0x063DBF60;     // FMistDataSerializer(char, bool)
constexpr std::uintptr_t kRvaClientUpdateData = 0x06229730;   // UMistDataBrokerPlayerComponent::ClientUpdateData
constexpr std::uintptr_t kRvaClientTransmitReady = 0x06229700;
constexpr std::uintptr_t kRvaClientCompleteInitialSync = 0x062296D0;
constexpr std::uintptr_t kRvaFindDataItem = 0x063D0D20;       // TMap<FMistDataKey, UMistData*>::Find
constexpr std::uintptr_t kRvaWeakAssign = 0x015EF020;         // FWeakObjectPtr::operator=(FObjectPtr)
constexpr std::uintptr_t kRvaWeakGet = 0x015F2E20;            // FWeakObjectPtr::Get
constexpr std::uintptr_t kRvaGetOwnerRole = 0x03A992A0;       // UActorComponent::GetOwnerRole
// ---- game data ---------------------------------------------------------------------------
constexpr std::uintptr_t kRvaSerializeSize = 0x0C1882BC;      // FMistDataSerializer::SerializeSize (int)
constexpr std::uintptr_t kRvaBurstRpcsCvar = 0x0C188288;      // -> int: batches per burst
constexpr std::uintptr_t kRvaBurstBytesCvar = 0x0C188270;     // -> int: bytes per burst

// ---- layouts -----------------------------------------------------------------------------
// UMistDataBrokerComponent
constexpr std::size_t kBrokerItems = 0xE8;          // TMap<FMistDataKey, UMistData*> (sparse array of 0x28)
constexpr std::size_t kBrokerItemsNum = 0xF0;       // int32 sparse array slots
constexpr std::size_t kBrokerItemFlags = 0xF8;      // TBitArray inline words (4 x uint32)
constexpr std::size_t kBrokerItemFlagsHeap = 0x108; // heap words, when not inline
constexpr std::size_t kBrokerItemFlagBits = 0x110;  // int32 NumBits
constexpr std::size_t kBrokerDirty = 0x138;         // TArray<UMistData*>
constexpr std::size_t kBrokerDirtyNum = 0x140;
constexpr std::size_t kBrokerDeleted = 0x148;       // TArray<{FGuid, uint32}> (0x14)
constexpr std::size_t kBrokerDeletedNum = 0x150;
constexpr std::size_t kBrokerSeats = 0x1C0;         // FWeakObjectPtr[3]
constexpr std::size_t kItemStride = 0x28;
constexpr std::size_t kItemValue = 0x18;
constexpr std::size_t kDeletedStride = 0x14;
// UMistData
constexpr std::size_t kDataGuid = 0x78;
constexpr std::size_t kDataWireType = 0x90;
constexpr std::size_t kDataKeyType = 0x91;
constexpr std::size_t kDataPendingMask = 0xA0;
// UMistDataBrokerPlayerComponent
constexpr std::size_t kCompOwner = 0xB0;       // AActor* (the player controller)
constexpr std::size_t kCompSeatIndex = 0xEC;   // int32, -1 = not seated
// AActor
constexpr std::size_t kActorRemoteRole = 0x68; // ENetRole
constexpr unsigned char kRoleAutonomousProxy = 2;
constexpr int kRoleAuthority = 3;

constexpr int kSerializerSize = 0x148;
constexpr int kSerializerCount = 0x140;
constexpr int kEntriesPerBatch = 8;
constexpr ULONGLONG kMinBurstGapMs = 100;
constexpr int kMaxItems = 4 * 1000 * 1000;

#pragma pack(push, 1)
struct DataKey
{
    unsigned char guid[16];
    unsigned char type;
    unsigned char pad[3];
};
struct SerializerEntry
{
    void* data;
    unsigned char wireType;
    unsigned char pad0[3];
    unsigned char guid[16];
    std::uint32_t pad1;
    std::uint64_t mask;
};
#pragma pack(pop)
static_assert(sizeof(DataKey) == 0x14, "FMistDataKey");
static_assert(sizeof(SerializerEntry) == 0x28, "FMistDataSerializer entry");

struct KeyId
{
    std::uint64_t lo;
    std::uint64_t hi;
    unsigned char type;
    bool operator==(const KeyId& other) const { return lo == other.lo && hi == other.hi && type == other.type; }
};
struct KeyIdHash
{
    std::size_t operator()(const KeyId& key) const
    {
        std::uint64_t h = key.lo * 0x9E3779B97F4A7C15ull;
        h ^= (key.hi + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2));
        h ^= (static_cast<std::uint64_t>(key.type) + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2));
        return static_cast<std::size_t>(h);
    }
};

KeyId IdOf(const DataKey& key)
{
    KeyId id{};
    std::memcpy(&id.lo, key.guid, 8);
    std::memcpy(&id.hi, key.guid + 8, 8);
    id.type = key.type;
    return id;
}

struct Node
{
    DataKey key;
    bool isDelete;
    unsigned char wireType;
};

struct SideClient
{
    void* broker = nullptr;
    void* comp = nullptr;
    std::uint64_t weak = 0; // FWeakObjectPtr
    bool ready = true;      // the component is constructed transmit-ready
    bool initialDone = false;
    int initialRemaining = 0;
    int rate = 1;
    int backlogBursts = 0;
    ULONGLONG lastBurstMs = 0;
    ULONGLONG adoptedMs = 0;
    std::deque<Node> queue;
    std::unordered_map<KeyId, std::uint64_t, KeyIdHash> pending;
    std::uint64_t batches = 0;
    std::uint64_t entries = 0;
    std::uint64_t bytes = 0;
};

struct Captured
{
    struct Update
    {
        DataKey key;
        std::uint64_t mask;
    };
    struct Delete
    {
        DataKey key;
        unsigned char wireType;
    };
    std::vector<Update> updates;
    std::vector<Delete> deletes;
};

using BrokerClientFn = void (*)(void* broker, void* comp);
using TickFn = void (*)(void* broker, float deltaTime, int tickType, void* tickFunction);
using SerializerCtorFn = void* (*)(void* self, char clientIndex, bool initialSync);
using ClientUpdateDataFn = void (*)(void* comp, const void* serializer);
using CompFn = void (*)(void* comp);
using FindFn = void* (*)(void* items, const void* key);
using WeakAssignFn = void (*)(void* weak, void** object);
using WeakGetFn = void* (*)(void* weak);
using GetOwnerRoleFn = int (*)(void* component);

std::uintptr_t g_base = 0;
bool g_installTried = false;
bool g_installed = false;
bool g_inTick = false;
std::wstring g_logPath;
std::vector<SideClient> g_clients;
std::uint64_t g_adoptions = 0;
ULONGLONG g_lastStatusMs = 0;

BrokerClientFn g_origAddClient = nullptr;
BrokerClientFn g_origRemoveClient = nullptr;
BrokerClientFn g_origMarkTransmitReady = nullptr;
TickFn g_origTick = nullptr;
SerializerCtorFn g_serializerCtor = nullptr;
ClientUpdateDataFn g_clientUpdateData = nullptr;
CompFn g_clientTransmitReady = nullptr;
CompFn g_clientCompleteInitialSync = nullptr;
FindFn g_findItem = nullptr;
WeakAssignFn g_weakAssign = nullptr;
WeakGetFn g_weakGet = nullptr;
GetOwnerRoleFn g_getOwnerRole = nullptr;

template <typename T>
T& At(void* object, std::size_t offset)
{
    return *reinterpret_cast<T*>(static_cast<unsigned char*>(object) + offset);
}

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

std::wstring EnvOr(const wchar_t* name, const std::wstring& fallback)
{
    wchar_t buffer[MAX_PATH * 2] = {};
    const DWORD len = GetEnvironmentVariableW(name, buffer, static_cast<DWORD>(sizeof(buffer) / sizeof(buffer[0])));
    if (len == 0 || len >= sizeof(buffer) / sizeof(buffer[0])) return fallback;
    return std::wstring(buffer, len);
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

void ResolveLogPath()
{
    if (!g_logPath.empty()) return;
    std::wstring host = EnvOr(L"HEARTH_HOST_LOG", EnvOr(L"BW_HOST_LOG", L""));
    const auto slash = host.find_last_of(L"\\/");
    if (slash != std::wstring::npos)
        g_logPath = host.substr(0, slash) + L"\\bw_seat4.log";
    else
        g_logPath = ModuleDirectory() + L"\\bw_seat4.log";
}

void Log(const char* format, ...)
{
    ResolveLogPath();
    char message[768];
    va_list args;
    va_start(args, format);
    std::vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    SYSTEMTIME now{};
    GetLocalTime(&now);
    char line[900];
    const int len = std::snprintf(line, sizeof(line), "%02u:%02u:%02u [bw_seat4] %s\r\n", now.wHour, now.wMinute,
        now.wSecond, message);
    if (len <= 0) return;
    HANDLE file = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(std::min<int>(len, sizeof(line) - 1)), &written, nullptr);
    CloseHandle(file);
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

// ---- detours -----------------------------------------------------------------------------
// Every hooked prologue below is position independent, so the stolen bytes run unchanged
// from the trampoline.
struct HookSite
{
    const char* name;
    std::uintptr_t rva;
    std::size_t length;
    unsigned char expected[18];
    void* hook;
    void** original;
    unsigned char* trampoline;
};

void WriteAbsoluteJump(unsigned char* at, const void* target)
{
    at[0] = 0xFF;
    at[1] = 0x25;
    at[2] = at[3] = at[4] = at[5] = 0x00;
    std::memcpy(at + 6, &target, sizeof(target));
}

bool PrepareHook(HookSite& site)
{
    const auto* target = reinterpret_cast<const unsigned char*>(g_base + site.rva);
    if (!IsReadable(target, site.length) || std::memcmp(target, site.expected, site.length) != 0)
    {
        Log("install refused: %s prologue does not match build 24840601", site.name);
        return false;
    }
    site.trampoline = static_cast<unsigned char*>(
        VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!site.trampoline)
    {
        Log("install refused: no memory for the %s trampoline", site.name);
        return false;
    }
    std::memcpy(site.trampoline, target, site.length);
    WriteAbsoluteJump(site.trampoline + site.length, target + site.length);
    FlushInstructionCache(GetCurrentProcess(), site.trampoline, 64);
    return true;
}

bool CommitHook(HookSite& site)
{
    auto* target = reinterpret_cast<unsigned char*>(g_base + site.rva);
    DWORD oldProtect = 0;
    if (!VirtualProtect(target, site.length, PAGE_EXECUTE_READWRITE, &oldProtect))
    {
        Log("install failed: cannot unprotect %s", site.name);
        return false;
    }
    *site.original = site.trampoline;
    unsigned char patch[18];
    std::memset(patch, 0x90, sizeof(patch));
    WriteAbsoluteJump(patch, site.hook);
    std::memcpy(target, patch, site.length);
    DWORD ignored = 0;
    VirtualProtect(target, site.length, oldProtect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), target, site.length);
    return true;
}

// ---- side clients ------------------------------------------------------------------------
SideClient* FindClient(void* comp)
{
    for (auto& client : g_clients)
        if (client.comp == comp) return &client;
    return nullptr;
}

void DropClient(void* comp, const char* why)
{
    for (auto it = g_clients.begin(); it != g_clients.end(); ++it)
    {
        if (it->comp != comp) continue;
        Log("released comp=%p reason=%s batches=%llu entries=%llu bytes=%llu queued=%zu initial_done=%d", comp, why,
            static_cast<unsigned long long>(it->batches), static_cast<unsigned long long>(it->entries),
            static_cast<unsigned long long>(it->bytes), it->queue.size(), it->initialDone ? 1 : 0);
        g_clients.erase(it);
        return;
    }
}

int SeatsTaken(void* broker)
{
    int taken = 0;
    for (int i = 0; i < 3; ++i)
        if (At<std::uint64_t>(broker, kBrokerSeats + 8 * i) != 0) ++taken;
    return taken;
}

// Queue every object the broker holds, all fields: what AddClient does for a seated player.
int QueueEverything(void* broker, SideClient& client)
{
    auto* items = At<unsigned char*>(broker, kBrokerItems);
    const int slots = At<std::int32_t>(broker, kBrokerItemsNum);
    const int bits = At<std::int32_t>(broker, kBrokerItemFlagBits);
    if (!items || slots <= 0 || bits <= 0 || slots > kMaxItems || bits > kMaxItems) return 0;
    auto* words = At<std::uint32_t*>(broker, kBrokerItemFlagsHeap);
    if (!words) words = &At<std::uint32_t>(broker, kBrokerItemFlags);
    const int limit = std::min(slots, bits);
    int queued = 0;
    for (int i = 0; i < limit; ++i)
    {
        if ((words[i >> 5] & (1u << (i & 31))) == 0) continue;
        unsigned char* element = items + static_cast<std::size_t>(i) * kItemStride;
        void* data = *reinterpret_cast<void**>(element + kItemValue);
        if (!data) continue;
        Node node{};
        std::memcpy(node.key.guid, element, 16);
        node.key.type = element[16];
        node.isDelete = false;
        const KeyId id = IdOf(node.key);
        if (client.pending.find(id) != client.pending.end()) continue;
        client.pending.emplace(id, ~0ull);
        client.queue.push_back(node);
        ++queued;
    }
    return queued;
}

void Adopt(void* broker, void* comp)
{
    SideClient client;
    client.broker = broker;
    client.comp = comp;
    void* object = comp;
    g_weakAssign(&client.weak, &object);
    client.adoptedMs = GetTickCount64();
    client.initialRemaining = QueueEverything(broker, client);
    ++g_adoptions;
    Log("adopted comp=%p broker=%p seats_taken=%d objects=%d side_players=%zu (no free data seat in the game)", comp,
        broker, SeatsTaken(broker), client.initialRemaining, g_clients.size() + 1);
    g_clients.push_back(std::move(client));
}

void HookAddClient(void* broker, void* comp)
{
    g_origAddClient(broker, comp);
    if (!broker || !comp) return;
    if (g_getOwnerRole(broker) != kRoleAuthority) return;
    void* owner = At<void*>(comp, kCompOwner);
    if (!owner || At<unsigned char>(owner, kActorRemoteRole) != kRoleAutonomousProxy) return;
    SideClient* existing = FindClient(comp);
    if (At<std::int32_t>(comp, kCompSeatIndex) != -1)
    {
        if (existing) DropClient(comp, "seated-by-game");
        return;
    }
    if (existing && existing->broker == broker) return; // a second ReadyForData from the same join
    if (existing) DropClient(comp, "broker-changed");
    if (SeatsTaken(broker) < 3) return; // not a full house; the game refused for another reason
    Adopt(broker, comp);
}

void HookRemoveClient(void* broker, void* comp)
{
    g_origRemoveClient(broker, comp);
    if (comp && FindClient(comp)) DropClient(comp, "left");
}

void HookMarkTransmitReady(void* broker, void* comp)
{
    g_origMarkTransmitReady(broker, comp);
    if (SideClient* client = comp ? FindClient(comp) : nullptr) client->ready = true;
}

int ReadCvar(std::uintptr_t rva, int fallback, int low, int high)
{
    auto* holder = reinterpret_cast<int**>(g_base + rva);
    if (!IsReadable(holder, sizeof(*holder)) || !*holder || !IsReadable(*holder, sizeof(int))) return fallback;
    const int value = **holder;
    return (value < low || value > high) ? fallback : value;
}

void Capture(void* broker, Captured& captured)
{
    auto** dirty = At<void**>(broker, kBrokerDirty);
    const int dirtyNum = At<std::int32_t>(broker, kBrokerDirtyNum);
    if (dirty && dirtyNum > 0 && dirtyNum <= kMaxItems)
    {
        captured.updates.reserve(static_cast<std::size_t>(dirtyNum));
        for (int i = 0; i < dirtyNum; ++i)
        {
            void* data = dirty[i];
            if (!data) continue;
            const std::uint64_t mask = At<std::uint64_t>(data, kDataPendingMask);
            if (mask == 0) continue;
            Captured::Update update{};
            std::memcpy(update.key.guid, static_cast<unsigned char*>(data) + kDataGuid, 16);
            update.key.type = At<unsigned char>(data, kDataKeyType);
            update.mask = mask;
            captured.updates.push_back(update);
        }
    }
    auto* deleted = At<unsigned char*>(broker, kBrokerDeleted);
    const int deletedNum = At<std::int32_t>(broker, kBrokerDeletedNum);
    if (deleted && deletedNum > 0 && deletedNum <= kMaxItems)
    {
        captured.deletes.reserve(static_cast<std::size_t>(deletedNum));
        for (int i = 0; i < deletedNum; ++i)
        {
            const unsigned char* entry = deleted + static_cast<std::size_t>(i) * kDeletedStride;
            Captured::Delete del{};
            std::memcpy(del.key.guid, entry, 16);
            del.key.type = entry[16];
            del.wireType = entry[16];
            captured.deletes.push_back(del);
        }
    }
}

void Merge(SideClient& client, const Captured& captured)
{
    for (const auto& update : captured.updates)
    {
        const KeyId id = IdOf(update.key);
        auto it = client.pending.find(id);
        if (it != client.pending.end())
        {
            it->second |= update.mask;
            continue;
        }
        client.pending.emplace(id, update.mask);
        Node node{};
        node.key = update.key;
        node.isDelete = false;
        client.queue.push_back(node);
    }
    for (const auto& del : captured.deletes)
    {
        Node node{};
        node.key = del.key;
        node.isDelete = true;
        node.wireType = del.wireType;
        client.queue.push_back(node);
    }
}

void Burst(void* broker, SideClient& client, void* comp, ULONGLONG now)
{
    alignas(16) unsigned char serializer[kSerializerSize];
    g_serializerCtor(serializer, 0, !client.initialDone);
    auto* entries = reinterpret_cast<SerializerEntry*>(serializer);
    auto& count = *reinterpret_cast<signed char*>(serializer + kSerializerCount);
    const int maxBatches = ReadCvar(kRvaBurstRpcsCvar, 4, 1, 256) * client.rate;
    const int maxBytes = ReadCvar(kRvaBurstBytesCvar, 16 * 1024, 256, 4 * 1024 * 1024);
    const int* serializedSize = reinterpret_cast<const int*>(g_base + kRvaSerializeSize);
    int batches = 0;
    int bytes = 0;
    while (!client.queue.empty())
    {
        const Node node = client.queue.front();
        client.queue.pop_front();
        if (client.initialRemaining > 0) --client.initialRemaining;
        if (node.isDelete)
        {
            SerializerEntry& entry = entries[count];
            std::memset(&entry, 0, sizeof(entry));
            entry.wireType = node.wireType;
            std::memcpy(entry.guid, node.key.guid, 16);
            ++count;
        }
        else
        {
            std::uint64_t mask = 0;
            auto it = client.pending.find(IdOf(node.key));
            if (it != client.pending.end())
            {
                mask = it->second;
                client.pending.erase(it);
            }
            DataKey key = node.key;
            void* element = mask ? g_findItem(static_cast<unsigned char*>(broker) + kBrokerItems, &key) : nullptr;
            void* data = element ? At<void*>(element, kItemValue) : nullptr;
            if (data)
            {
                SerializerEntry& entry = entries[count];
                std::memset(&entry, 0, sizeof(entry));
                entry.data = data;
                entry.wireType = At<unsigned char>(data, kDataWireType);
                std::memcpy(entry.guid, static_cast<unsigned char*>(data) + kDataGuid, 16);
                entry.mask = mask;
                ++count;
            }
        }
        if (count < kEntriesPerBatch) continue;
        client.entries += static_cast<std::uint64_t>(count);
        g_clientUpdateData(comp, serializer);
        client.ready = false;
        bytes += *serializedSize;
        ++batches;
        count = 0;
        if (batches >= maxBatches || bytes >= maxBytes) break;
    }
    if (count > 0)
    {
        client.entries += static_cast<std::uint64_t>(count);
        g_clientUpdateData(comp, serializer);
        client.ready = false;
        bytes += *serializedSize;
        ++batches;
        count = 0;
    }
    client.batches += static_cast<std::uint64_t>(batches);
    client.bytes += static_cast<std::uint64_t>(bytes);
    if (!client.ready) g_clientTransmitReady(comp);
    if (client.initialRemaining <= 0 && !client.initialDone)
    {
        g_clientCompleteInitialSync(comp);
        client.initialDone = true;
        Log("first full pass sent comp=%p in %llu ms batches=%llu entries=%llu bytes=%llu", comp,
            static_cast<unsigned long long>(now - client.adoptedMs), static_cast<unsigned long long>(client.batches),
            static_cast<unsigned long long>(client.entries), static_cast<unsigned long long>(client.bytes));
    }
    if (!client.queue.empty() && client.initialDone)
    {
        if (++client.backlogBursts >= 5)
        {
            client.backlogBursts = 0;
            client.rate = std::min(3, client.rate + 1);
        }
    }
    else
    {
        client.backlogBursts = 0;
        client.rate = 1;
    }
    client.lastBurstMs = now;
}

void Serve(void* broker, const Captured& captured)
{
    const ULONGLONG now = GetTickCount64();
    for (std::size_t i = 0; i < g_clients.size();)
    {
        SideClient& client = g_clients[i];
        if (client.broker != broker)
        {
            ++i;
            continue;
        }
        void* comp = g_weakGet(&client.weak);
        if (!comp || comp != client.comp)
        {
            DropClient(client.comp, "gone");
            continue;
        }
        if (At<std::int32_t>(comp, kCompSeatIndex) != -1)
        {
            DropClient(client.comp, "seated-by-game");
            continue;
        }
        Merge(client, captured);
        if (client.ready && now - client.lastBurstMs >= kMinBurstGapMs) Burst(broker, client, comp, now);
        ++i;
    }
}

void HookTick(void* broker, float deltaTime, int tickType, void* tickFunction)
{
    bool mine = false;
    if (!g_inTick && broker)
    {
        for (const auto& client : g_clients)
        {
            if (client.broker == broker)
            {
                mine = true;
                break;
            }
        }
    }
    if (!mine)
    {
        g_origTick(broker, deltaTime, tickType, tickFunction);
        return;
    }
    g_inTick = true;
    Captured captured;
    Capture(broker, captured);
    g_origTick(broker, deltaTime, tickType, tickFunction);
    Serve(broker, captured);
    g_inTick = false;
}

// ---- install -----------------------------------------------------------------------------
void Install()
{
    g_installTried = true;
    const std::wstring off = EnvOr(L"HEARTH_FOURTH_SEAT", L"1");
    if (off == L"0")
    {
        Log("disabled by HEARTH_FOURTH_SEAT=0");
        return;
    }
    if (!ReadModuleBase())
    {
        Log("install refused: not Bellwright build 24840601 (module or image size)");
        return;
    }
    g_serializerCtor = reinterpret_cast<SerializerCtorFn>(g_base + kRvaSerializerCtor);
    g_clientUpdateData = reinterpret_cast<ClientUpdateDataFn>(g_base + kRvaClientUpdateData);
    g_clientTransmitReady = reinterpret_cast<CompFn>(g_base + kRvaClientTransmitReady);
    g_clientCompleteInitialSync = reinterpret_cast<CompFn>(g_base + kRvaClientCompleteInitialSync);
    g_findItem = reinterpret_cast<FindFn>(g_base + kRvaFindDataItem);
    g_weakAssign = reinterpret_cast<WeakAssignFn>(g_base + kRvaWeakAssign);
    g_weakGet = reinterpret_cast<WeakGetFn>(g_base + kRvaWeakGet);
    g_getOwnerRole = reinterpret_cast<GetOwnerRoleFn>(g_base + kRvaGetOwnerRole);

    // Called, not hooked: refuse the whole install if any of them moved.
    struct Probe
    {
        const char* name;
        std::uintptr_t rva;
        unsigned char expected[8];
    };
    const Probe probes[] = {
        {"FMistDataSerializer ctor", kRvaSerializerCtor, {0x33, 0xC0, 0x48, 0x89, 0x01, 0x88, 0x41, 0x08}},
        {"ClientUpdateData", kRvaClientUpdateData, {0x48, 0x89, 0x5C, 0x24, 0x18, 0x57, 0x48, 0x81}},
        {"ClientTransmitReady", kRvaClientTransmitReady, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B}},
        {"ClientCompleteInitialSync", kRvaClientCompleteInitialSync, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B}},
        {"TMap Find", kRvaFindDataItem, {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74}},
        {"FWeakObjectPtr assign", kRvaWeakAssign, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B}},
        {"FWeakObjectPtr Get", kRvaWeakGet, {0x44, 0x8B, 0x49, 0x04, 0x45, 0x85, 0xC9, 0x74}},
        {"GetOwnerRole", kRvaGetOwnerRole, {0x48, 0x8B, 0x81, 0xB0, 0x00, 0x00, 0x00, 0x48}},
    };
    for (const auto& probe : probes)
    {
        const auto* at = reinterpret_cast<const unsigned char*>(g_base + probe.rva);
        if (!IsReadable(at, sizeof(probe.expected)) || std::memcmp(at, probe.expected, sizeof(probe.expected)) != 0)
        {
            Log("install refused: %s does not match build 24840601", probe.name);
            return;
        }
    }

    HookSite sites[] = {
        {"AddClient", kRvaAddClient, 16,
            {0x40, 0x55, 0x53, 0x56, 0x48, 0x8D, 0x6C, 0x24, 0xB9, 0x48, 0x81, 0xEC, 0xB0, 0x00, 0x00, 0x00},
            reinterpret_cast<void*>(&HookAddClient), reinterpret_cast<void**>(&g_origAddClient), nullptr},
        {"RemoveClient", kRvaRemoveClient, 16,
            {0x48, 0x89, 0x5C, 0x24, 0x10, 0x57, 0x48, 0x83, 0xEC, 0x60, 0x48, 0x8B, 0xDA, 0x48, 0x8B, 0xF9},
            reinterpret_cast<void*>(&HookRemoveClient), reinterpret_cast<void**>(&g_origRemoveClient), nullptr},
        {"MarkTransmitReady", kRvaMarkTransmitReady, 16,
            {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0xFA, 0x48, 0x8B, 0xD9},
            reinterpret_cast<void*>(&HookMarkTransmitReady), reinterpret_cast<void**>(&g_origMarkTransmitReady),
            nullptr},
        {"TickComponent", kRvaTickComponent, 18,
            {0x40, 0x55, 0x57, 0x48, 0x8D, 0xAC, 0x24, 0x78, 0xFE, 0xFF, 0xFF, 0x48, 0x81, 0xEC, 0x88, 0x02, 0x00,
                0x00},
            reinterpret_cast<void*>(&HookTick), reinterpret_cast<void**>(&g_origTick), nullptr},
    };
    for (auto& site : sites)
        if (!PrepareHook(site)) return;
    for (auto& site : sites)
        if (!CommitHook(site))
        {
            Log("install incomplete at %s: the host keeps running on the game's three data seats", site.name);
            return;
        }
    g_installed = true;
    Log("installed for Bellwright 24840601: unseated players get world data beside the game's three seats");
}

void WriteStatusFile()
{
    const std::wstring path = ModuleDirectory() + L"\\fourth-seat-status.txt";
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    const char* body = g_installed ? "installed=1\r\n" : "installed=0\r\n";
    DWORD written = 0;
    WriteFile(file, body, static_cast<DWORD>(std::strlen(body)), &written, nullptr);
    CloseHandle(file);
}

void Status()
{
    const ULONGLONG now = GetTickCount64();
    if (now - g_lastStatusMs < 60000) return;
    g_lastStatusMs = now;
    for (const auto& client : g_clients)
        Log("serving comp=%p initial_done=%d ready=%d queued=%zu batches=%llu entries=%llu bytes=%llu", client.comp,
            client.initialDone ? 1 : 0, client.ready ? 1 : 0, client.queue.size(),
            static_cast<unsigned long long>(client.batches), static_cast<unsigned long long>(client.entries),
            static_cast<unsigned long long>(client.bytes));
}
} // namespace

// Called by the bw_seat4 Lua mod on the game thread.  The first call installs and writes
// fourth-seat-status.txt beside this DLL; later calls log a status line a minute while
// somebody is being served.  It is a lua_CFunction: the return value is the number of Lua
// results, so it is always 0.
extern "C" __declspec(dllexport) int HearthFourthSeat_Service(void*)
{
    if (!g_installTried)
    {
        Install();
        WriteStatusFile();
    }
    if (g_installed) Status();
    return 0;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}
