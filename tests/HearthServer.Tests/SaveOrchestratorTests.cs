using FluentAssertions;
using HearthServer.Services;

namespace HearthServer.Tests;

public sealed class SaveOrchestratorTests
{
    [Theory]
    [InlineData("savegame_0.sav")]
    [InlineData("savegame_27.sav")]
    [InlineData("TEMP_auto.sav")]
    [InlineData("temp_AUTO.sav_backup0")]
    [InlineData("TEMP_auto.sav_backup1")]
    [InlineData("TEMP_auto_today.sav")]
    [InlineData("TEMP_auto_yesterday.sav")]
    public void IsRootSaveSlotPath_AcceptsKnownBellwrightSaveNames(string path)
    {
        SaveOrchestratorService.IsRootSaveSlotPath(path).Should().BeTrue();
    }

    [Theory]
    [InlineData("SaveGames/TEMP_auto.sav")]
    [InlineData("backup/TEMP_auto_today.sav")]
    [InlineData("TEMP_auto.sav.tmp")]
    [InlineData("TEMP_manual.sav")]
    [InlineData("notes.txt")]
    public void IsRootSaveSlotPath_RejectsNestedOrUnrelatedFiles(string path)
    {
        SaveOrchestratorService.IsRootSaveSlotPath(path).Should().BeFalse();
    }
}
