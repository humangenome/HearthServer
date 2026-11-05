// Hearth.Identity join password gate: the parts that do not touch the game, so they build and are tested on any OS
// (tests/join_gate_test.cpp). The Windows plugin (IdentityPlugin.cpp) feeds them the join options, the joiner's address
// and HearthServer's gate file, and refuses the login when Check() says so.
//
// Why: until 2026-11-02 a join password set for a Hearth server reached nothing on the host. The Hearth app already
// sends the password the player saved or typed as ?HearthKey= on every join (HearthConnect), and HearthServer now writes
// the owner's password, salted and hashed, to HearthServer\data\join-gate.txt. The gate compares the two inside
// AMistOasisGameMode::PreLogin, before anything is keyed, so a refused player never gets a character record.
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>

namespace hearth::joingate
{
// Gate file: "open" (no password) or "v1 <64 hex>" where the hex is PasswordDigest(password). HearthServer writes it on
// every start (JoinGateFile in HearthServer); the same digest is tested on both sides (shared vector).
constexpr const char* kDigestPrefix = "hearth-join-v1\n";

// A wrong password from one address is counted once per distinct password: the app's join retries resend the same one.
constexpr int kWindowSeconds = 600;     // distinct wrong passwords are counted over 10 minutes
constexpr int kMaxDistinctWrong = 5;    // the 5th distinct wrong password in that window ...
constexpr int kBlockSeconds = 600;      // ... makes the address wait 10 minutes (every join refused, right or wrong)
constexpr std::size_t kMaxAddresses = 1024;

// The whitespace PHP's trim() and HearthServer strip: space, tab, LF, CR, NUL, vertical tab.
std::string TrimPassword(const std::string& password);

// Lowercase hex SHA-256 of kDigestPrefix + TrimPassword(password).
std::string PasswordDigest(const std::string& password);

enum class Mode
{
    Open,   // no password: every join goes on as before
    Locked, // a password is set: only a join carrying it gets in
    Broken, // the file is there but unreadable: every join is refused until HearthServer rewrites it
};

struct Config
{
    Mode mode = Mode::Open;
    std::string digest; // Locked only
};

Config ParseGateFile(const std::string& text);

// "203.0.113.7:7777" -> "203.0.113.7", "[2001:db8::1]:7777" -> "2001:db8::1"; anything else unchanged.
std::string AddressKey(const std::string& address);

struct AddressRecord
{
    std::int64_t windowStart = 0;
    std::int64_t blockedUntil = 0;
    std::int64_t lastSeen = 0;
    std::set<std::string> wrong; // first 16 hex of each distinct wrong digest
};

struct Limiter
{
    std::map<std::string, AddressRecord> records;
};

struct Verdict
{
    bool allow = true;
    std::string reason; // plain words for the log; never contains the password or its digest
};

// options: the join's URL options ("?Name=a?HearthKey=b..."). now: unix seconds. The limiter is updated.
Verdict Check(const Config& config, const std::string& options, const std::string& address, std::int64_t now, Limiter& limiter);
} // namespace hearth::joingate
