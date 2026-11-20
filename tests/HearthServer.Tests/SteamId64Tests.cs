using FluentAssertions;
using HearthServer.Services;

namespace HearthServer.Tests;

// A personal Steam account: 17 ASCII digits, account 1 to 2^32-1. IDs that start 7656120 (accounts above
// 2,039,734,271) are as valid as the 7656119 ones every account has had so far.
public sealed class SteamId64Tests
{
    [Theory]
    [InlineData("76561197960265729")] // account 1, the lowest
    [InlineData("76561198000000001")]
    [InlineData("76561200000000001")] // starts 7656120
    [InlineData("76561202255233023")] // account 2^32-1, the highest
    public void Accepts_every_personal_account(string id) =>
        SteamId64.IsValid(id).Should().BeTrue();

    [Theory]
    [InlineData("76561197960265728")] // account 0
    [InlineData("76561202255233024")] // past account 2^32-1
    [InlineData("7656119800000000")] // 16 digits
    [InlineData("765611980000000011")] // 18 digits
    [InlineData("7656119800000000a")]
    [InlineData(" 76561198000000001")]
    [InlineData("76561198000000001 ")]
    [InlineData("76561198000000001\n")]
    [InlineData("7656119800000000\n")]
    [InlineData("７６５６１１９８００００００００１")] // fullwidth digits
    [InlineData("")]
    [InlineData(null)]
    public void Refuses_anything_else(string? id) =>
        SteamId64.IsValid(id).Should().BeFalse();
}
