#include "JoinGateCore.hpp"

#include "IdentityCore.hpp"

namespace hearth::joingate
{
namespace
{
bool IsTrimmed(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\0' || c == '\x0B'; }

bool IsLowerHex64(const std::string& s)
{
    if (s.size() != 64) return false;
    for (const char c : s)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}

bool SameDigest(const std::string& a, const std::string& b)
{
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (std::size_t i = 0; i < a.size(); ++i) diff |= static_cast<unsigned char>(a[i] ^ b[i]);
    return diff == 0;
}

void Evict(Limiter& limiter, const std::string& keep)
{
    while (limiter.records.size() > kMaxAddresses)
    {
        auto oldest = limiter.records.end();
        for (auto it = limiter.records.begin(); it != limiter.records.end(); ++it)
        {
            if (it->first == keep) continue;
            if (oldest == limiter.records.end() || it->second.lastSeen < oldest->second.lastSeen) oldest = it;
        }
        if (oldest == limiter.records.end()) return;
        limiter.records.erase(oldest);
    }
}
} // namespace

std::string TrimPassword(const std::string& password)
{
    std::size_t start = 0;
    std::size_t end = password.size();
    while (start < end && IsTrimmed(password[start])) ++start;
    while (end > start && IsTrimmed(password[end - 1])) --end;
    return password.substr(start, end - start);
}

std::string PasswordDigest(const std::string& password)
{
    return hearth::identity::Sha256Hex(std::string(kDigestPrefix) + TrimPassword(password));
}

Config ParseGateFile(const std::string& text)
{
    Config config;
    std::string body = TrimPassword(text);
    if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF && static_cast<unsigned char>(body[1]) == 0xBB &&
        static_cast<unsigned char>(body[2]) == 0xBF)
        body = TrimPassword(body.substr(3));
    if (body == "open") return config;
    if (body.size() == 67 && body.compare(0, 3, "v1 ") == 0)
    {
        std::string hex = body.substr(3);
        for (char& c : hex)
            if (c >= 'A' && c <= 'F') c = static_cast<char>(c - 'A' + 'a');
        if (IsLowerHex64(hex))
        {
            config.mode = Mode::Locked;
            config.digest = hex;
            return config;
        }
    }
    config.mode = Mode::Broken;
    return config;
}

std::string AddressKey(const std::string& address)
{
    if (!address.empty() && address.front() == '[')
    {
        const auto close = address.find(']');
        if (close != std::string::npos) return address.substr(1, close - 1);
        return address;
    }
    const auto colon = address.find(':');
    if (colon != std::string::npos && address.find(':', colon + 1) == std::string::npos) return address.substr(0, colon);
    return address;
}

Verdict Check(const Config& config, const std::string& options, const std::string& address, std::int64_t now, Limiter& limiter)
{
    Verdict v;
    if (config.mode == Mode::Open)
    {
        v.reason = "open server";
        return v;
    }
    if (config.mode == Mode::Broken)
    {
        v.allow = false;
        v.reason = "join-gate file unreadable: every join is refused until HearthServer rewrites it";
        return v;
    }

    const std::string key = AddressKey(address);
    auto found = limiter.records.find(key);
    if (found != limiter.records.end() && found->second.blockedUntil > now)
    {
        found->second.lastSeen = now;
        v.allow = false;
        v.reason = "refused: this address is waiting after " + std::to_string(kMaxDistinctWrong) + " wrong passwords (" +
                   std::to_string(found->second.blockedUntil - now) + " s left)";
        return v;
    }

    const std::string presented = TrimPassword(hearth::identity::OptionValue(options, "HearthKey"));
    if (presented.empty())
    {
        v.allow = false;
        v.reason = "refused: no password in the join (the player's app has none saved)";
        return v;
    }

    const std::string digest = PasswordDigest(presented);
    if (SameDigest(digest, config.digest))
    {
        if (found != limiter.records.end()) limiter.records.erase(found);
        v.reason = "password OK";
        return v;
    }

    AddressRecord& record = limiter.records[key];
    if (record.windowStart == 0 || now - record.windowStart >= kWindowSeconds)
    {
        record.windowStart = now;
        record.wrong.clear();
    }
    record.lastSeen = now;
    record.wrong.insert(digest.substr(0, 16));
    v.allow = false;
    if (static_cast<int>(record.wrong.size()) >= kMaxDistinctWrong)
    {
        record.blockedUntil = now + kBlockSeconds;
        record.wrong.clear();
        record.windowStart = 0;
        v.reason = "refused: wrong password; " + std::to_string(kMaxDistinctWrong) +
                   " different wrong passwords from this address, it now waits " + std::to_string(kBlockSeconds / 60) +
                   " minutes";
    }
    else
    {
        v.reason = "refused: wrong password (" + std::to_string(record.wrong.size()) + " different wrong in " +
                   std::to_string(kWindowSeconds / 60) + " min from this address)";
    }
    Evict(limiter, key);
    return v;
}
} // namespace hearth::joingate
