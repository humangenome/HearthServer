#include <windows.h>

#include <fstream>
#include <iostream>
#include <string>

extern "C" int HearthGameplaySettings_TestParse(const wchar_t* path);

namespace
{
constexpr char kValidConfig[] =
    "revision=cccd65e3e4e3f9e68b5ea501e3acc4a4e7523d4d23ea809042b826c0f15ea90e\r\n"
    "managed=1\r\n"
    "raids_enabled=1\r\n"
    "raids_on_outposts=1\r\n"
    "raid_frequency=1\r\n"
    "raid_strength=4\r\n"
    "brigands_raid_frequency=1\r\n"
    "brigands_raid_strength=1\r\n"
    "bandits_migration_frequency=2\r\n"
    "multiple_threats=0\r\n"
    "weapon_requirements=1\r\n"
    "armor_requirements=1\r\n"
    "food_spoilage_speed=1.00\r\n"
    "hunger_speed=1.35\r\n"
    "equipment_breaking_speed=1.00\r\n"
    "skills_learning_speed=1.00\r\n"
    "melee_damage=1.00\r\n"
    "ranged_damage=1.00\r\n"
    "village_needs=1.00\r\n"
    "village_needs_prosperity_reward=1.00\r\n"
    "village_needs_prosperity_penalty=1.00\r\n"
    "fishing_difficulty=1\r\n"
    "show_dialogue_choice_effects=1\r\n";

bool Write(const std::wstring& path, const std::string& contents)
{
    std::ofstream output(path.c_str(), std::ios::binary | std::ios::trunc);
    output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    return static_cast<bool>(output);
}
}

int main()
{
    wchar_t directory[MAX_PATH]{};
    if (!GetTempPathW(MAX_PATH, directory)) return 10;
    const std::wstring path = std::wstring(directory) + L"hearth-gameplay-settings-parser-test.cfg";

    if (!Write(path, kValidConfig) || HearthGameplaySettings_TestParse(path.c_str()) != 1)
    {
        std::cerr << "valid canonical config was rejected\n";
        DeleteFileW(path.c_str());
        return 1;
    }

    std::string tampered = kValidConfig;
    tampered.replace(tampered.find("hunger_speed=1.35"), 17, "hunger_speed=1.40");
    if (!Write(path, tampered) || HearthGameplaySettings_TestParse(path.c_str()) != 0)
    {
        std::cerr << "tampered revision was accepted\n";
        DeleteFileW(path.c_str());
        return 2;
    }

    std::string duplicate = kValidConfig;
    duplicate += "raids_enabled=1\r\n";
    if (!Write(path, duplicate) || HearthGameplaySettings_TestParse(path.c_str()) != 0)
    {
        std::cerr << "duplicate key was accepted\n";
        DeleteFileW(path.c_str());
        return 3;
    }

    if (!Write(path, "revision=bad\r\n") || HearthGameplaySettings_TestParse(path.c_str()) != 0)
    {
        std::cerr << "incomplete config was accepted\n";
        DeleteFileW(path.c_str());
        return 4;
    }

    DeleteFileW(path.c_str());
    std::cout << "Hearth gameplay settings parser tests passed\n";
    return 0;
}
