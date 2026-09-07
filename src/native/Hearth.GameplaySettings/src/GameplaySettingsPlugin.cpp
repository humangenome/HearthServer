#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <limits>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

namespace
{
constexpr wchar_t kGameModule[] = L"BellwrightGame-Win64-Shipping.exe";
constexpr char kExpectedExeSha256[] = "9bdb3795ef97ff0f253cf3ed070cb559d453cea4dc1c640274e8f766265edce6";
constexpr std::uintptr_t kSettingsSingletonRva = 0x0c188358;
constexpr std::uintptr_t kExpectedImageSize = 0x0ce02000;

constexpr std::uintptr_t kSetRaidsEnabled = 0x020049a0;
constexpr std::uintptr_t kSetRaidsOnOutposts = 0x064001f0;
constexpr std::uintptr_t kSetRaidFrequency = 0x0239c470;
constexpr std::uintptr_t kSetRaidStrength = 0x0239c4e0;
constexpr std::uintptr_t kSetBrigandsRaidFrequency = 0x0239c520;
constexpr std::uintptr_t kSetBrigandsRaidStrength = 0x063ffe00;
constexpr std::uintptr_t kSetBanditsMigrationFrequency = 0x063ffdc0;
constexpr std::uintptr_t kSetMultipleThreats = 0x064000e0;
constexpr std::uintptr_t kSetWeaponRequirements = 0x06400560;
constexpr std::uintptr_t kSetArmorRequirements = 0x04ec9a20;
constexpr std::uintptr_t kSetFoodSpoilageSpeed = 0x063ffe80;
constexpr std::uintptr_t kSetHungerSpeed = 0x06400030;
constexpr std::uintptr_t kSetEquipmentBreakingSpeed = 0x063ffe60;
constexpr std::uintptr_t kSetSkillsLearningSpeed = 0x0436a100;
constexpr std::uintptr_t kSetMeleeDamage = 0x064000d0;
constexpr std::uintptr_t kSetRangedDamage = 0x064002b0;
constexpr std::uintptr_t kSetVillageNeeds = 0x0457c660;
constexpr std::uintptr_t kSetVillageNeedsReward = 0x06400550;
constexpr std::uintptr_t kSetVillageNeedsPenalty = 0x06400540;
constexpr std::uintptr_t kSetFishingDifficulty = 0x063ffe70;
constexpr std::uintptr_t kSetShowDialogueChoiceEffects = 0x06400310;

constexpr std::uintptr_t kGetRaidsEnabled = 0x0127ca60;
constexpr std::uintptr_t kGetRaidsOnOutposts = 0x063f9670;
constexpr std::uintptr_t kGetRaidFrequency = 0x063f9420;
constexpr std::uintptr_t kGetRaidStrength = 0x036701b0;
constexpr std::uintptr_t kGetBrigandsRaidFrequency = 0x063f7130;
constexpr std::uintptr_t kGetBrigandsRaidStrength = 0x063f72d0;
constexpr std::uintptr_t kGetBanditsMigrationFrequency = 0x063f6fc0;
constexpr std::uintptr_t kGetMultipleThreats = 0x063f8790;
constexpr std::uintptr_t kGetWeaponRequirements = 0x063f9b60;
constexpr std::uintptr_t kGetArmorRequirements = 0x063f6e90;
constexpr std::uintptr_t kGetFoodSpoilageSpeed = 0x063f8480;
constexpr std::uintptr_t kGetHungerSpeed = 0x063f85e0;
constexpr std::uintptr_t kGetEquipmentBreakingSpeed = 0x063f82c0;
constexpr std::uintptr_t kGetSkillsLearningSpeed = 0x0435d310;
constexpr std::uintptr_t kGetMeleeDamage = 0x0435d320;
constexpr std::uintptr_t kGetRangedDamage = 0x04eb31b0;
constexpr std::uintptr_t kGetVillageNeeds = 0x045797a0;
constexpr std::uintptr_t kGetVillageNeedsReward = 0x063f9b50;
constexpr std::uintptr_t kGetVillageNeedsPenalty = 0x063f9b40;
constexpr std::uintptr_t kGetFishingDifficulty = 0x063f8470;
constexpr std::uintptr_t kGetShowDialogueChoiceEffects = 0x063f9840;

constexpr std::uintptr_t kMarkPersistenceDirty = 0x0669fdb0;
constexpr std::uintptr_t kMarkDirtyBit = 0x063fbca0;
constexpr std::uintptr_t kPersistentInterfaceOffset = 0xc8;

constexpr std::array<const char*, 22> kCanonicalKeys = {
    "managed",
    "raids_enabled",
    "raids_on_outposts",
    "raid_frequency",
    "raid_strength",
    "brigands_raid_frequency",
    "brigands_raid_strength",
    "bandits_migration_frequency",
    "multiple_threats",
    "weapon_requirements",
    "armor_requirements",
    "food_spoilage_speed",
    "hunger_speed",
    "equipment_breaking_speed",
    "skills_learning_speed",
    "melee_damage",
    "ranged_damage",
    "village_needs",
    "village_needs_prosperity_reward",
    "village_needs_prosperity_penalty",
    "fishing_difficulty",
    "show_dialogue_choice_effects",
};

struct Settings
{
    bool raidsEnabled{};
    bool raidsOnOutposts{};
    std::uint8_t raidFrequency{};
    std::uint8_t raidStrength{};
    std::uint8_t brigandsRaidFrequency{};
    std::uint8_t brigandsRaidStrength{};
    std::uint8_t banditsMigrationFrequency{};
    bool multipleThreats{};
    bool weaponRequirements{};
    bool armorRequirements{};
    float foodSpoilageSpeed{};
    float hungerSpeed{};
    float equipmentBreakingSpeed{};
    float skillsLearningSpeed{};
    float meleeDamage{};
    float rangedDamage{};
    float villageNeeds{};
    float villageNeedsReward{};
    float villageNeedsPenalty{};
    std::uint8_t fishingDifficulty{};
    bool showDialogueChoiceEffects{};
};

struct ParsedConfig
{
    bool managed{};
    std::string revision;
    std::map<std::string, std::string> values;
    Settings settings;
};

std::mutex g_mutex;
std::string g_verifiedRevision;
std::atomic<int> g_buildState{0}; // 0=not started, 1=checking, 2=valid, 3=invalid

std::wstring GetEnvironmentPath(const wchar_t* name)
{
    const wchar_t* value = _wgetenv(name);
    return value && *value ? std::wstring(value) : std::wstring();
}

std::string Hex(const std::vector<std::uint8_t>& bytes)
{
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (std::uint8_t byte : bytes) out << std::setw(2) << static_cast<unsigned>(byte);
    return out.str();
}

bool Sha256Buffer(const std::uint8_t* data, std::size_t size, std::string& digest)
{
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objectSize = 0;
    DWORD hashSize = 0;
    DWORD received = 0;
    std::vector<std::uint8_t> object;
    std::vector<std::uint8_t> result;

    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
    const auto closeAlgorithm = [&]() { if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); };
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectSize),
            sizeof(objectSize), &received, 0) < 0
        || BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&hashSize),
            sizeof(hashSize), &received, 0) < 0)
    {
        closeAlgorithm();
        return false;
    }
    object.resize(objectSize);
    result.resize(hashSize);
    if (BCryptCreateHash(algorithm, &hash, object.data(), objectSize, nullptr, 0, 0) < 0)
    {
        closeAlgorithm();
        return false;
    }
    bool ok = size <= std::numeric_limits<ULONG>::max()
        && BCryptHashData(hash, const_cast<PUCHAR>(data), static_cast<ULONG>(size), 0) >= 0
        && BCryptFinishHash(hash, result.data(), hashSize, 0) >= 0;
    BCryptDestroyHash(hash);
    closeAlgorithm();
    if (!ok) return false;
    digest = Hex(result);
    return true;
}

bool Sha256File(const std::wstring& path, std::string& digest)
{
    std::ifstream input(path.c_str(), std::ios::binary);
    if (!input) return false;

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objectSize = 0;
    DWORD hashSize = 0;
    DWORD received = 0;
    std::vector<std::uint8_t> object;
    std::vector<std::uint8_t> result;
    std::array<char, 1024 * 1024> buffer{};

    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectSize),
            sizeof(objectSize), &received, 0) < 0
        || BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&hashSize),
            sizeof(hashSize), &received, 0) < 0)
    {
        BCryptCloseAlgorithmProvider(algorithm, 0);
        return false;
    }
    object.resize(objectSize);
    result.resize(hashSize);
    if (BCryptCreateHash(algorithm, &hash, object.data(), objectSize, nullptr, 0, 0) < 0)
    {
        BCryptCloseAlgorithmProvider(algorithm, 0);
        return false;
    }

    bool ok = true;
    while (input)
    {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto count = input.gcount();
        if (count > 0 && BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()),
                static_cast<ULONG>(count), 0) < 0)
        {
            ok = false;
            break;
        }
    }
    if (!input.eof()) ok = false;
    if (ok && BCryptFinishHash(hash, result.data(), hashSize, 0) < 0) ok = false;
    BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!ok) return false;
    digest = Hex(result);
    return true;
}

bool WriteStatus(const std::wstring& path, const std::string& contents)
{
    if (path.empty()) return false;
    const std::wstring temporary = path + L".tmp." + std::to_wstring(GetCurrentProcessId());
    {
        std::ofstream output(temporary.c_str(), std::ios::binary | std::ios::trunc);
        if (!output) return false;
        output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
        output.flush();
        if (!output) return false;
    }
    if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    {
        DeleteFileW(temporary.c_str());
        return false;
    }
    return true;
}

void WriteError(const std::wstring& statusPath, const char* error)
{
    WriteStatus(statusPath, std::string("state=error\r\nerror=") + error + "\r\n");
}

bool StatusMatches(const std::wstring& path, const std::string& expected)
{
    std::ifstream input(path.c_str(), std::ios::binary);
    if (!input) return false;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str() == expected;
}

bool ParseBool(const std::string& value, bool& parsed)
{
    if (value == "0") { parsed = false; return true; }
    if (value == "1") { parsed = true; return true; }
    return false;
}

bool ParseEnum(const std::string& value, int maximum, std::uint8_t& parsed)
{
    if (value.size() != 1 || value[0] < '0' || value[0] > static_cast<char>('0' + maximum)) return false;
    parsed = static_cast<std::uint8_t>(value[0] - '0');
    return true;
}

bool ParseFloat(const std::string& value, float minimum, float maximum, float& parsed)
{
    if (value.empty() || value.size() > 16) return false;
    char* end = nullptr;
    parsed = std::strtof(value.c_str(), &end);
    return end == value.c_str() + value.size() && std::isfinite(parsed)
        && parsed >= minimum && parsed <= maximum;
}

bool IsLowerHexSha256(const std::string& value)
{
    if (value.size() != 64) return false;
    for (char c : value)
    {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

bool ParseConfig(const std::wstring& path, ParsedConfig& config, std::string& error)
{
    std::ifstream input(path.c_str(), std::ios::binary);
    if (!input) { error = "config_missing"; return false; }
    std::ostringstream raw;
    raw << input.rdbuf();
    const std::string contents = raw.str();
    if (contents.empty() || contents.size() > 8192) { error = "config_size"; return false; }

    std::istringstream lines(contents);
    std::string line;
    while (std::getline(lines, line))
    {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        const auto separator = line.find('=');
        if (separator == std::string::npos || separator == 0 || separator + 1 >= line.size())
        {
            error = "config_line";
            return false;
        }
        const std::string key = line.substr(0, separator);
        const std::string value = line.substr(separator + 1);
        if ((key != "revision" && std::find(kCanonicalKeys.begin(), kCanonicalKeys.end(), key) == kCanonicalKeys.end())
            || config.values.contains(key))
        {
            error = "config_key";
            return false;
        }
        config.values.emplace(key, value);
    }

    if (config.values.size() != kCanonicalKeys.size() + 1)
    {
        error = "config_count";
        return false;
    }
    config.revision = config.values["revision"];
    if (!IsLowerHexSha256(config.revision) || config.values["managed"] != "1")
    {
        error = "config_header";
        return false;
    }
    config.managed = true;

    std::string canonical;
    for (const char* key : kCanonicalKeys) canonical += std::string(key) + "=" + config.values[key] + "\n";
    std::string calculated;
    if (!Sha256Buffer(reinterpret_cast<const std::uint8_t*>(canonical.data()), canonical.size(), calculated)
        || calculated != config.revision)
    {
        error = "config_revision";
        return false;
    }

    Settings& s = config.settings;
    if (!ParseBool(config.values["raids_enabled"], s.raidsEnabled)
        || !ParseBool(config.values["raids_on_outposts"], s.raidsOnOutposts)
        || !ParseEnum(config.values["raid_frequency"], 2, s.raidFrequency)
        || !ParseEnum(config.values["raid_strength"], 4, s.raidStrength)
        || !ParseEnum(config.values["brigands_raid_frequency"], 2, s.brigandsRaidFrequency)
        || !ParseEnum(config.values["brigands_raid_strength"], 4, s.brigandsRaidStrength)
        || !ParseEnum(config.values["bandits_migration_frequency"], 3, s.banditsMigrationFrequency)
        || !ParseBool(config.values["multiple_threats"], s.multipleThreats)
        || !ParseBool(config.values["weapon_requirements"], s.weaponRequirements)
        || !ParseBool(config.values["armor_requirements"], s.armorRequirements)
        || !ParseFloat(config.values["food_spoilage_speed"], 0.25f, 2.0f, s.foodSpoilageSpeed)
        || !ParseFloat(config.values["hunger_speed"], 0.25f, 2.0f, s.hungerSpeed)
        || !ParseFloat(config.values["equipment_breaking_speed"], 0.25f, 2.0f, s.equipmentBreakingSpeed)
        || !ParseFloat(config.values["skills_learning_speed"], 0.5f, 2.0f, s.skillsLearningSpeed)
        || !ParseFloat(config.values["melee_damage"], 0.25f, 4.0f, s.meleeDamage)
        || !ParseFloat(config.values["ranged_damage"], 0.25f, 4.0f, s.rangedDamage)
        || !ParseFloat(config.values["village_needs"], 0.25f, 2.0f, s.villageNeeds)
        || !ParseFloat(config.values["village_needs_prosperity_reward"], 0.5f, 2.0f, s.villageNeedsReward)
        || !ParseFloat(config.values["village_needs_prosperity_penalty"], 0.25f, 2.0f, s.villageNeedsPenalty)
        || !ParseEnum(config.values["fishing_difficulty"], 3, s.fishingDifficulty)
        || !ParseBool(config.values["show_dialogue_choice_effects"], s.showDialogueChoiceEffects))
    {
        error = "config_value";
        return false;
    }
    return true;
}

bool IsReadable(const void* pointer, std::size_t size)
{
    if (!pointer || size == 0) return false;
    MEMORY_BASIC_INFORMATION info{};
    if (VirtualQuery(pointer, &info, sizeof(info)) != sizeof(info) || info.State != MEM_COMMIT
        || (info.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return false;
    const auto start = reinterpret_cast<std::uintptr_t>(pointer);
    const auto end = start + size;
    const auto regionEnd = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
    return end >= start && end <= regionEnd;
}

bool VerifyBuild(std::uintptr_t& base)
{
    HMODULE module = GetModuleHandleW(kGameModule);
    if (!module) return false;
    base = reinterpret_cast<std::uintptr_t>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (!IsReadable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (!IsReadable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE
        || nt->OptionalHeader.SizeOfImage != kExpectedImageSize) return false;

    wchar_t modulePath[32768]{};
    const DWORD length = GetModuleFileNameW(module, modulePath, static_cast<DWORD>(std::size(modulePath)));
    if (length == 0 || length >= std::size(modulePath)) return false;
    std::string digest;
    return Sha256File(modulePath, digest) && digest == kExpectedExeSha256;
}

DWORD WINAPI VerifyBuildThread(void*)
{
    std::uintptr_t base = 0;
    g_buildState.store(VerifyBuild(base) ? 2 : 3, std::memory_order_release);
    return 0;
}

bool ReadModuleBase(std::uintptr_t& base)
{
    HMODULE module = GetModuleHandleW(kGameModule);
    if (!module) return false;
    base = reinterpret_cast<std::uintptr_t>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (!IsReadable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    return IsReadable(nt, sizeof(*nt)) && nt->Signature == IMAGE_NT_SIGNATURE
        && nt->OptionalHeader.SizeOfImage == kExpectedImageSize;
}

template <typename T>
T Function(std::uintptr_t base, std::uintptr_t rva)
{
    return reinterpret_cast<T>(base + rva);
}

bool Near(float actual, float expected)
{
    return std::fabs(actual - expected) <= 0.0005f;
}

bool ApplyAndVerify(std::uintptr_t base, void* object, const Settings& s, std::string& readback)
{
    using SetBool = void (*)(void*, bool);
    using SetEnum = void (*)(void*, std::uint8_t);
    using SetFloat = void (*)(void*, float);
    using GetBool = bool (*)(const void*);
    using GetEnum = std::uint8_t (*)(const void*);
    using GetFloat = float (*)(const void*);
    using MarkPersistence = void (*)(void*);
    using MarkDirty = void (*)(void*, std::uint8_t);

    Function<SetBool>(base, kSetRaidsEnabled)(object, s.raidsEnabled);
    Function<SetBool>(base, kSetRaidsOnOutposts)(object, s.raidsOnOutposts);
    Function<SetEnum>(base, kSetRaidFrequency)(object, s.raidFrequency);
    Function<SetEnum>(base, kSetRaidStrength)(object, s.raidStrength);
    Function<SetEnum>(base, kSetBrigandsRaidFrequency)(object, s.brigandsRaidFrequency);
    Function<SetEnum>(base, kSetBrigandsRaidStrength)(object, s.brigandsRaidStrength);
    Function<SetEnum>(base, kSetBanditsMigrationFrequency)(object, s.banditsMigrationFrequency);
    Function<SetBool>(base, kSetMultipleThreats)(object, s.multipleThreats);
    Function<SetBool>(base, kSetWeaponRequirements)(object, s.weaponRequirements);
    Function<SetBool>(base, kSetArmorRequirements)(object, s.armorRequirements);
    Function<SetFloat>(base, kSetFoodSpoilageSpeed)(object, s.foodSpoilageSpeed);
    Function<SetFloat>(base, kSetHungerSpeed)(object, s.hungerSpeed);
    Function<SetFloat>(base, kSetEquipmentBreakingSpeed)(object, s.equipmentBreakingSpeed);
    Function<SetFloat>(base, kSetSkillsLearningSpeed)(object, s.skillsLearningSpeed);
    Function<SetFloat>(base, kSetMeleeDamage)(object, s.meleeDamage);
    Function<SetFloat>(base, kSetRangedDamage)(object, s.rangedDamage);
    Function<SetFloat>(base, kSetVillageNeeds)(object, s.villageNeeds);
    Function<SetFloat>(base, kSetVillageNeedsReward)(object, s.villageNeedsReward);
    Function<SetFloat>(base, kSetVillageNeedsPenalty)(object, s.villageNeedsPenalty);
    Function<SetEnum>(base, kSetFishingDifficulty)(object, s.fishingDifficulty);
    Function<SetBool>(base, kSetShowDialogueChoiceEffects)(object, s.showDialogueChoiceEffects);

    Function<MarkPersistence>(base, kMarkPersistenceDirty)(
        reinterpret_cast<void*>(reinterpret_cast<std::uintptr_t>(object) + kPersistentInterfaceOffset));
    Function<MarkDirty>(base, kMarkDirtyBit)(object, 0);

    const bool raidsEnabled = Function<GetBool>(base, kGetRaidsEnabled)(object);
    const bool raidsOnOutposts = Function<GetBool>(base, kGetRaidsOnOutposts)(object);
    const auto raidFrequency = Function<GetEnum>(base, kGetRaidFrequency)(object);
    const auto raidStrength = Function<GetEnum>(base, kGetRaidStrength)(object);
    const auto brigandsRaidFrequency = Function<GetEnum>(base, kGetBrigandsRaidFrequency)(object);
    const auto brigandsRaidStrength = Function<GetEnum>(base, kGetBrigandsRaidStrength)(object);
    const auto banditsMigrationFrequency = Function<GetEnum>(base, kGetBanditsMigrationFrequency)(object);
    const bool multipleThreats = Function<GetBool>(base, kGetMultipleThreats)(object);
    const bool weaponRequirements = Function<GetBool>(base, kGetWeaponRequirements)(object);
    const bool armorRequirements = Function<GetBool>(base, kGetArmorRequirements)(object);
    const float foodSpoilageSpeed = Function<GetFloat>(base, kGetFoodSpoilageSpeed)(object);
    const float hungerSpeed = Function<GetFloat>(base, kGetHungerSpeed)(object);
    const float equipmentBreakingSpeed = Function<GetFloat>(base, kGetEquipmentBreakingSpeed)(object);
    const float skillsLearningSpeed = Function<GetFloat>(base, kGetSkillsLearningSpeed)(object);
    const float meleeDamage = Function<GetFloat>(base, kGetMeleeDamage)(object);
    const float rangedDamage = Function<GetFloat>(base, kGetRangedDamage)(object);
    const float villageNeeds = Function<GetFloat>(base, kGetVillageNeeds)(object);
    const float villageNeedsReward = Function<GetFloat>(base, kGetVillageNeedsReward)(object);
    const float villageNeedsPenalty = Function<GetFloat>(base, kGetVillageNeedsPenalty)(object);
    const auto fishingDifficulty = Function<GetEnum>(base, kGetFishingDifficulty)(object);
    const bool showDialogueChoiceEffects = Function<GetBool>(base, kGetShowDialogueChoiceEffects)(object);

    std::ostringstream status;
    status << std::fixed << std::setprecision(2)
        << "raids_enabled=" << (raidsEnabled ? 1 : 0) << "\r\n"
        << "raids_on_outposts=" << (raidsOnOutposts ? 1 : 0) << "\r\n"
        << "raid_frequency=" << static_cast<unsigned>(raidFrequency) << "\r\n"
        << "raid_strength=" << static_cast<unsigned>(raidStrength) << "\r\n"
        << "brigands_raid_frequency=" << static_cast<unsigned>(brigandsRaidFrequency) << "\r\n"
        << "brigands_raid_strength=" << static_cast<unsigned>(brigandsRaidStrength) << "\r\n"
        << "bandits_migration_frequency=" << static_cast<unsigned>(banditsMigrationFrequency) << "\r\n"
        << "multiple_threats=" << (multipleThreats ? 1 : 0) << "\r\n"
        << "weapon_requirements=" << (weaponRequirements ? 1 : 0) << "\r\n"
        << "armor_requirements=" << (armorRequirements ? 1 : 0) << "\r\n"
        << "food_spoilage_speed=" << foodSpoilageSpeed << "\r\n"
        << "hunger_speed=" << hungerSpeed << "\r\n"
        << "equipment_breaking_speed=" << equipmentBreakingSpeed << "\r\n"
        << "skills_learning_speed=" << skillsLearningSpeed << "\r\n"
        << "melee_damage=" << meleeDamage << "\r\n"
        << "ranged_damage=" << rangedDamage << "\r\n"
        << "village_needs=" << villageNeeds << "\r\n"
        << "village_needs_prosperity_reward=" << villageNeedsReward << "\r\n"
        << "village_needs_prosperity_penalty=" << villageNeedsPenalty << "\r\n"
        << "fishing_difficulty=" << static_cast<unsigned>(fishingDifficulty) << "\r\n"
        << "show_dialogue_choice_effects=" << (showDialogueChoiceEffects ? 1 : 0) << "\r\n";
    readback = status.str();

    return raidsEnabled == s.raidsEnabled
        && raidsOnOutposts == s.raidsOnOutposts
        && raidFrequency == s.raidFrequency
        && raidStrength == s.raidStrength
        && brigandsRaidFrequency == s.brigandsRaidFrequency
        && brigandsRaidStrength == s.brigandsRaidStrength
        && banditsMigrationFrequency == s.banditsMigrationFrequency
        && multipleThreats == s.multipleThreats
        && weaponRequirements == s.weaponRequirements
        && armorRequirements == s.armorRequirements
        && Near(foodSpoilageSpeed, s.foodSpoilageSpeed)
        && Near(hungerSpeed, s.hungerSpeed)
        && Near(equipmentBreakingSpeed, s.equipmentBreakingSpeed)
        && Near(skillsLearningSpeed, s.skillsLearningSpeed)
        && Near(meleeDamage, s.meleeDamage)
        && Near(rangedDamage, s.rangedDamage)
        && Near(villageNeeds, s.villageNeeds)
        && Near(villageNeedsReward, s.villageNeedsReward)
        && Near(villageNeedsPenalty, s.villageNeedsPenalty)
        && fishingDifficulty == s.fishingDifficulty
        && showDialogueChoiceEffects == s.showDialogueChoiceEffects;
}

void Service()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    const std::wstring configPath = GetEnvironmentPath(L"HEARTH_GAMEPLAY_SETTINGS_FILE");
    const std::wstring statusPath = GetEnvironmentPath(L"HEARTH_GAMEPLAY_SETTINGS_STATUS");
    if (statusPath.empty()) return;
    if (configPath.empty() || GetFileAttributesW(configPath.c_str()) == INVALID_FILE_ATTRIBUTES)
    {
        const std::string unmanaged = "state=unmanaged\r\n";
        if (g_verifiedRevision != "unmanaged" || !StatusMatches(statusPath, unmanaged))
        {
            WriteStatus(statusPath, unmanaged);
        }
        g_verifiedRevision = "unmanaged";
        return;
    }

    ParsedConfig config;
    std::string parseError;
    if (!ParseConfig(configPath, config, parseError))
    {
        g_verifiedRevision.clear();
        WriteError(statusPath, parseError.c_str());
        return;
    }

    int buildState = g_buildState.load(std::memory_order_acquire);
    if (buildState == 0)
    {
        int expected = 0;
        if (g_buildState.compare_exchange_strong(expected, 1, std::memory_order_acq_rel))
        {
            HANDLE thread = CreateThread(nullptr, 0, VerifyBuildThread, nullptr, 0, nullptr);
            if (thread) CloseHandle(thread);
            else g_buildState.store(3, std::memory_order_release);
        }
        buildState = g_buildState.load(std::memory_order_acquire);
    }
    if (buildState == 1)
    {
        WriteStatus(statusPath, "state=pending\r\nerror=build_check\r\n");
        return;
    }
    if (buildState != 2)
    {
        g_verifiedRevision.clear();
        WriteError(statusPath, "build_mismatch");
        return;
    }

    const std::string appliedPrefix = "state=applied\r\nrevision=" + config.revision + "\r\n";
    if (g_verifiedRevision == config.revision)
    {
        std::ifstream statusInput(statusPath.c_str(), std::ios::binary);
        std::ostringstream statusContents;
        if (statusInput) statusContents << statusInput.rdbuf();
        if (statusContents.str().rfind(appliedPrefix, 0) == 0) return;
    }

    std::uintptr_t base = 0;
    if (!ReadModuleBase(base))
    {
        g_buildState.store(3, std::memory_order_release);
        g_verifiedRevision.clear();
        WriteError(statusPath, "build_mismatch");
        return;
    }
    auto** singleton = reinterpret_cast<void**>(base + kSettingsSingletonRva);
    if (!IsReadable(singleton, sizeof(*singleton)) || !*singleton || !IsReadable(*singleton, 0x110))
    {
        WriteStatus(statusPath, "state=pending\r\nerror=settings_unavailable\r\n");
        return;
    }
    void* object = *singleton;
    void* vtable = *reinterpret_cast<void**>(object);
    const auto vtableAddress = reinterpret_cast<std::uintptr_t>(vtable);
    if (vtableAddress < base || vtableAddress >= base + kExpectedImageSize)
    {
        g_verifiedRevision.clear();
        WriteError(statusPath, "settings_identity");
        return;
    }

    std::string readback;
    if (!ApplyAndVerify(base, object, config.settings, readback))
    {
        g_verifiedRevision.clear();
        WriteStatus(statusPath, "state=error\r\nerror=readback_mismatch\r\n" + readback);
        return;
    }
    if (!WriteStatus(statusPath, "state=applied\r\nrevision=" + config.revision + "\r\n" + readback))
    {
        g_verifiedRevision.clear();
        return;
    }
    g_verifiedRevision = config.revision;
}
} // namespace

extern "C" __declspec(dllexport) int HearthGameplaySettings_Service(void*)
{
    Service();
    return 0;
}

#ifdef HEARTH_GAMEPLAY_SETTINGS_TEST
extern "C" int HearthGameplaySettings_TestParse(const wchar_t* path)
{
    ParsedConfig config;
    std::string error;
    return path && ParseConfig(path, config, error) ? 1 : 0;
}
#endif

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}
