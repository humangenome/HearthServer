// Run (one line): g++ -std=c++20 -O1 -Wall -Wextra -Werror -I src/native/Hearth.Identity/src
//   src/native/Hearth.Identity/src/IdentityCore.cpp src/native/Hearth.Identity/tests/identity_core_test.cpp
//   -o /tmp/identity_core_test && /tmp/identity_core_test
// Checks the character-follows-Steam decision on its own: SHA-256 / HMAC against published vectors, the join options,
// the token (signature, Steam ID, expiry, lifetime, one use) and the swap rule.
#include "IdentityCore.hpp"

#include <cstdio>
#include <string>

using namespace hearth::identity;

static int g_fail = 0, g_n = 0;
static void Check(bool ok, const char* what)
{
    ++g_n;
    std::printf("%s - %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) ++g_fail;
}

static std::string Hex(const std::string& s)
{
    static const char* d = "0123456789abcdef";
    std::string o;
    for (unsigned char c : s) { o.push_back(d[c >> 4]); o.push_back(d[c & 15]); }
    return o;
}

static std::string MakeToken(const std::string& key, const std::string& payload)
{
    return Hex(payload) + "." + HmacSha256Hex(key, payload);
}

int main()
{
    // published vectors
    Check(Sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 of the empty string");
    Check(Sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc");
    Check(Sha256Hex(std::string(1000000, 'a')) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        "SHA-256 of a million a's (multi-block)");
    Check(HmacSha256Hex(std::string(20, '\x0b'), "Hi There") ==
              "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "HMAC-SHA256 RFC 4231 case 1");
    Check(HmacSha256Hex("Jefe", "what do ya want for nothing?") ==
              "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA256 RFC 4231 case 2");
    Check(HmacSha256Hex(std::string(131, '\xaa'), "Test Using Larger Than Block-Size Key - Hash Key First") ==
              "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "HMAC-SHA256 RFC 4231 case 6 (long key)");

    // join options
    const std::string opts = "?Name=NEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A?PlayerId=76561199000000201"
                             "?PlatformUserId=76561199000000201?HearthDisplayName=Pat%20B?HearthIdToken=TOKEN";
    Check(OptionValue(opts, "PlayerId") == "76561199000000201", "reads ?PlayerId");
    Check(OptionValue(opts, "HearthDisplayName") == "Pat B", "decodes percent escapes");
    Check(OptionValue(opts, "Missing").empty(), "an absent option is empty");
    Check(IsComputerId("NEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A"), "a real computer id passes the shape check");
    Check(!IsComputerId("steam_76561199000000201") && !IsComputerId("x-1234"), "other names fail the shape check");
    Check(IsSteamId("76561199000000201") && !IsSteamId("7656119904823420") && !IsSteamId("1234567890123456a"),
        "Steam ID shape");

    // token
    const std::string key = "0123456789abcdef0123456789abcdef";
    const std::string steam = "76561199000000201";
    const std::int64_t now = 1793300000;
    const std::set<std::string> none;
    const std::string good = MakeToken(key, "v1|" + steam + "|" + std::to_string(now + 300) + "|00112233445566778899aabb");
    Check(VerifyToken(good, key, steam, now, none).ok, "a fresh token for this Steam ID is accepted");
    Check(VerifyToken(good, key, "76561199000000101", now, none).reason == "token is for another Steam ID",
        "the same token for another Steam ID is refused");
    std::string flipped = good; flipped[3] = flipped[3] == '0' ? '1' : '0';
    Check(VerifyToken(flipped, key, steam, now, none).reason == "token signature wrong", "a changed payload is refused");
    Check(!VerifyToken(good, "another-key-another-key-another!", steam, now, none).ok, "a token signed with another key is refused");
    const std::string old = MakeToken(key, "v1|" + steam + "|" + std::to_string(now - 1) + "|00112233445566778899aabb");
    Check(VerifyToken(old, key, steam, now, none).reason == "token expired", "an expired token is refused");
    const std::string longlived = MakeToken(key, "v1|" + steam + "|" + std::to_string(now + 7200) + "|00112233445566778899aabb");
    Check(VerifyToken(longlived, key, steam, now, none).reason == "token lifetime too long", "a token valid for hours is refused");
    const std::set<std::string> used{"00112233445566778899aabb"};
    Check(VerifyToken(good, key, steam, now, used).reason == "token already used", "a token is good for one join");
    Check(VerifyToken("zz.zz", key, steam, now, none).reason == "token malformed", "garbage is refused");
    Check(VerifyToken(good, "", steam, now, none).reason == "no token key", "no key on the server: nothing is accepted");

    // the cross-language vector (tests/HearthServer.Tests/IdentityTests.cs signs the same payload)
    Check(MakeToken(key, "v1|76561199000000201|1793300300|00112233445566778899aabb") ==
              "76317c37363536313139393030303030303230317c313739333330303330307c303031313232333334343535363637373838393961616262"
              ".ce495602dbc8d140c7766e8d5bc11f682cac14f701ec02cf34f55a1b6f158ea3",
        "HearthServer and the host mod build the same token");

    // map
    int skipped = -1;
    const auto m = ParseSteamMap("# steam64\tfirst computer id\n76561199000000201\tFIRST-PC-0A1B2C3D4E5F60718293A4B5C6D7E8F9\r\n"
                                 "76561199000000201\tNEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A\nnot a line\n"
                                 "76561199000000101\tsteam_x\n", &skipped);
    Check(m.size() == 1 && m.at(steam) == "FIRST-PC-0A1B2C3D4E5F60718293A4B5C6D7E8F9",
        "the map keeps the first computer for a Steam ID");
    Check(skipped == 2, "bad map lines are skipped and counted");

    // decision
    auto withToken = [&](const std::string& name, const std::string& tok) {
        return "?Name=" + name + "?PlayerId=" + steam + "?HearthIdToken=" + tok;
    };
    auto d = Decide(withToken("NEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A", good), key, m, now, none);
    Check(d.swap && d.to == "FIRST-PC-0A1B2C3D4E5F60718293A4B5C6D7E8F9" && !d.nonce.empty(),
        "a verified player on a new computer joins as the first computer's character");
    d = Decide(withToken("FIRST-PC-0A1B2C3D4E5F60718293A4B5C6D7E8F9", good), key, m, now, none);
    Check(!d.swap && !d.nonce.empty(), "on the first computer nothing changes (token still spent)");
    d = Decide("?Name=NEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A?PlayerId=" + steam, key, m, now, none);
    Check(!d.swap && d.nonce.empty(), "no token (old app): nothing changes");
    d = Decide(withToken("NEW-LAPTOP-F9E8D7C6B5A4938271605F4E3D2C1B0A", flipped), key, m, now, none);
    Check(!d.swap && d.nonce.empty(), "a forged token: nothing changes");
    const std::string other = "76561199000000101";
    const std::string otherTok = MakeToken(key, "v1|" + other + "|" + std::to_string(now + 300) + "|ffeeddccbbaa99887766");
    d = Decide("?Name=OTHER-PC-80B6302747F25BBBD1DA3EB2A7A21416?PlayerId=" + other + "?HearthIdToken=" + otherTok, key, m, now, none);
    Check(!d.swap && !d.nonce.empty(), "a Steam ID with no map entry yet: nothing changes (HearthServer records it)");
    d = Decide("?Name=OTHER-PC-80B6302747F25BBBD1DA3EB2A7A21416?PlayerId=" + steam + "?HearthIdToken=" + otherTok, key, m, now, none);
    Check(!d.swap, "someone else's token presented with this Steam ID: refused");

    std::printf("%d of %d identity checks passed\n", g_n - g_fail, g_n);
    return g_fail == 0 ? 0 : 1;
}
