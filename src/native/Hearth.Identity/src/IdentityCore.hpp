// Hearth.Identity core: the parts of the character-follows-Steam check that do not touch the game, so they build and
// are tested on any OS (tests/identity_core_test.cpp). The Windows plugin (IdentityPlugin.cpp) feeds them the join
// options, the token key and the Steam map, and swaps the player's id only when Decide() says so.
//
// Why: Bellwright keys a character on the engine's offline id (computer name + machine id); the MD5 of that string is
// the record's key and the record stores the string itself. A new or renamed computer therefore starts a new character.
// HearthServer issues a short-lived token after Steam has checked the player's ticket (see the server's identity
// service); with a valid token for Steam ID X, the join is pointed at the FIRST computer id HearthServer recorded for X.
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>

namespace hearth::identity
{
// Token = hex(payload) "." hex(HMAC-SHA256(key, payload)); payload = "v1|<steam64>|<expires unix s>|<nonce 16+ hex>".
constexpr int kMaxTokenLifetimeS = 600;

std::string Sha256Hex(const std::string& data);
std::string HmacSha256Hex(const std::string& key, const std::string& data);
bool HexDecode(const std::string& hex, std::string& out);

// Value of ?Key= in a URL options string ("?Name=a?PlayerId=1?..."); empty when absent. Percent escapes are decoded.
std::string OptionValue(const std::string& options, const std::string& key);

// Engine offline id shape: "<computer name>-<32 hex>".
bool IsComputerId(const std::string& id);
bool IsSteamId(const std::string& id);

struct TokenCheck
{
    bool ok = false;
    std::string reason; // plain words for the log; never contains the token
    std::string nonce;
};
// key: the raw key bytes. now: unix seconds. used: nonces already accepted in this process (checked, not changed).
TokenCheck VerifyToken(const std::string& token, const std::string& key, const std::string& steamId, std::int64_t now,
    const std::set<std::string>& used);

// "steam64<TAB>computer id" per line; bad lines are skipped and counted.
std::map<std::string, std::string> ParseSteamMap(const std::string& text, int* skipped = nullptr);

struct Decision
{
    bool swap = false;
    std::string to;     // the computer id to use when swap
    std::string reason; // plain words for the log
    std::string nonce;  // to remember as used when the token was accepted
};
Decision Decide(const std::string& options, const std::string& key, const std::map<std::string, std::string>& steamMap,
    std::int64_t now, const std::set<std::string>& used);
} // namespace hearth::identity
