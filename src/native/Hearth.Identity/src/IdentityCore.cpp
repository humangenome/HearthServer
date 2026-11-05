#include "IdentityCore.hpp"

#include <array>
#include <cctype>
#include <cstring>
#include <vector>

namespace hearth::identity
{
namespace
{
// ---- SHA-256 (FIPS 180-4), small and dependency free -------------------------------------------------------------
constexpr std::uint32_t kK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

inline std::uint32_t Rotr(std::uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

std::array<unsigned char, 32> Sha256(const std::string& data)
{
    std::uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    std::vector<unsigned char> msg(data.begin(), data.end());
    const std::uint64_t bits = static_cast<std::uint64_t>(data.size()) * 8u;
    msg.push_back(0x80);
    while (msg.size() % 64 != 56) msg.push_back(0);
    for (int i = 7; i >= 0; --i) msg.push_back(static_cast<unsigned char>(bits >> (i * 8)));
    for (std::size_t off = 0; off < msg.size(); off += 64)
    {
        std::uint32_t w[64];
        for (int i = 0; i < 16; ++i)
            w[i] = (std::uint32_t(msg[off + i * 4]) << 24) | (std::uint32_t(msg[off + i * 4 + 1]) << 16) |
                   (std::uint32_t(msg[off + i * 4 + 2]) << 8) | std::uint32_t(msg[off + i * 4 + 3]);
        for (int i = 16; i < 64; ++i)
        {
            const std::uint32_t s0 = Rotr(w[i - 15], 7) ^ Rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const std::uint32_t s1 = Rotr(w[i - 2], 17) ^ Rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        std::uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; ++i)
        {
            const std::uint32_t S1 = Rotr(e, 6) ^ Rotr(e, 11) ^ Rotr(e, 25);
            const std::uint32_t ch = (e & f) ^ (~e & g);
            const std::uint32_t t1 = hh + S1 + ch + kK[i] + w[i];
            const std::uint32_t S0 = Rotr(a, 2) ^ Rotr(a, 13) ^ Rotr(a, 22);
            const std::uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
            const std::uint32_t t2 = S0 + mj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    std::array<unsigned char, 32> out{};
    for (int i = 0; i < 8; ++i)
        for (int j = 0; j < 4; ++j) out[i * 4 + j] = static_cast<unsigned char>(h[i] >> (24 - j * 8));
    return out;
}

std::string ToHex(const unsigned char* p, std::size_t n)
{
    static const char* d = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (std::size_t i = 0; i < n; ++i) { s.push_back(d[p[i] >> 4]); s.push_back(d[p[i] & 15]); }
    return s;
}

int HexNibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Compare two equal-length strings without an early exit.
bool SameSecret(const std::string& a, const std::string& b)
{
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (std::size_t i = 0; i < a.size(); ++i) diff |= static_cast<unsigned char>(a[i] ^ b[i]);
    return diff == 0;
}

std::vector<std::string> Split(const std::string& s, char sep)
{
    std::vector<std::string> parts;
    std::size_t start = 0;
    for (;;)
    {
        const auto at = s.find(sep, start);
        parts.push_back(s.substr(start, at == std::string::npos ? std::string::npos : at - start));
        if (at == std::string::npos) break;
        start = at + 1;
    }
    return parts;
}
} // namespace

std::string Sha256Hex(const std::string& data)
{
    const auto d = Sha256(data);
    return ToHex(d.data(), d.size());
}

std::string HmacSha256Hex(const std::string& key, const std::string& data)
{
    std::string k = key;
    if (k.size() > 64) { const auto d = Sha256(k); k.assign(reinterpret_cast<const char*>(d.data()), d.size()); }
    k.resize(64, '\0');
    std::string ipad(64, '\0'), opad(64, '\0');
    for (int i = 0; i < 64; ++i) { ipad[i] = static_cast<char>(k[i] ^ 0x36); opad[i] = static_cast<char>(k[i] ^ 0x5c); }
    const auto inner = Sha256(ipad + data);
    const auto outer = Sha256(opad + std::string(reinterpret_cast<const char*>(inner.data()), inner.size()));
    return ToHex(outer.data(), outer.size());
}

bool HexDecode(const std::string& hex, std::string& out)
{
    if (hex.size() % 2 != 0) return false;
    out.clear();
    out.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2)
    {
        const int hi = HexNibble(hex[i]), lo = HexNibble(hex[i + 1]);
        if (hi < 0 || lo < 0) return false;
        out.push_back(static_cast<char>((hi << 4) | lo));
    }
    return true;
}

std::string OptionValue(const std::string& options, const std::string& key)
{
    const std::string needle = "?" + key + "=";
    const auto at = options.find(needle);
    if (at == std::string::npos) return "";
    const auto start = at + needle.size();
    const auto end = options.find('?', start);
    const std::string raw = options.substr(start, end == std::string::npos ? std::string::npos : end - start);
    std::string value;
    for (std::size_t i = 0; i < raw.size(); ++i)
    {
        if (raw[i] == '%' && i + 2 < raw.size())
        {
            const int hi = HexNibble(raw[i + 1]);
            const int lo = HexNibble(raw[i + 2]);
            if (hi >= 0 && lo >= 0) { value.push_back(static_cast<char>((hi << 4) | lo)); i += 2; continue; }
        }
        value.push_back(raw[i]);
    }
    return value;
}

bool IsComputerId(const std::string& id)
{
    if (id.size() < 34 || id.size() > 64 + 33) return false;
    const auto dash = id.size() - 33;
    if (id[dash] != '-') return false;
    for (std::size_t i = dash + 1; i < id.size(); ++i)
        if (!std::isxdigit(static_cast<unsigned char>(id[i]))) return false;
    for (std::size_t i = 0; i < dash; ++i)
    {
        const unsigned char c = static_cast<unsigned char>(id[i]);
        if (!(std::isalnum(c) || c == '_' || c == '.' || c == '-')) return false;
    }
    return true;
}

bool IsSteamId(const std::string& id)
{
    if (id.size() != 17 || id.rfind("7656", 0) != 0) return false;
    for (char c : id) if (c < '0' || c > '9') return false;
    return true;
}

TokenCheck VerifyToken(const std::string& token, const std::string& key, const std::string& steamId, std::int64_t now,
    const std::set<std::string>& used)
{
    TokenCheck r;
    if (key.size() < 16) { r.reason = "no token key"; return r; }
    const auto dot = token.find('.');
    if (dot == std::string::npos || token.size() > 512) { r.reason = "token malformed"; return r; }
    const std::string payloadHex = token.substr(0, dot), macHex = token.substr(dot + 1);
    std::string payload;
    if (!HexDecode(payloadHex, payload) || macHex.size() != 64) { r.reason = "token malformed"; return r; }
    std::string lowerMac = macHex;
    for (auto& c : lowerMac) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (!SameSecret(HmacSha256Hex(key, payload), lowerMac)) { r.reason = "token signature wrong"; return r; }
    const auto parts = Split(payload, '|');
    if (parts.size() != 4 || parts[0] != "v1") { r.reason = "token version unknown"; return r; }
    if (parts[1] != steamId) { r.reason = "token is for another Steam ID"; return r; }
    std::int64_t expires = 0;
    for (char c : parts[2]) { if (c < '0' || c > '9') { r.reason = "token expiry malformed"; return r; } expires = expires * 10 + (c - '0'); }
    if (expires < now) { r.reason = "token expired"; return r; }
    if (expires > now + kMaxTokenLifetimeS + 60) { r.reason = "token lifetime too long"; return r; }
    if (parts[3].size() < 16 || parts[3].size() > 64) { r.reason = "token nonce malformed"; return r; }
    for (char c : parts[3]) if (HexNibble(c) < 0) { r.reason = "token nonce malformed"; return r; }
    if (used.count(parts[3])) { r.reason = "token already used"; return r; }
    r.ok = true;
    r.nonce = parts[3];
    r.reason = "token ok";
    return r;
}

std::map<std::string, std::string> ParseSteamMap(const std::string& text, int* skipped)
{
    std::map<std::string, std::string> m;
    int bad = 0;
    for (auto line : Split(text, '\n'))
    {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        const auto tab = line.find('\t');
        if (tab == std::string::npos) { ++bad; continue; }
        const std::string steam = line.substr(0, tab);
        std::string id = line.substr(tab + 1);
        const auto tab2 = id.find('\t');
        if (tab2 != std::string::npos) id = id.substr(0, tab2);
        if (!IsSteamId(steam) || !IsComputerId(id)) { ++bad; continue; }
        m.emplace(steam, id); // the first line for a Steam ID wins
    }
    if (skipped) *skipped = bad;
    return m;
}

Decision Decide(const std::string& options, const std::string& key, const std::map<std::string, std::string>& steamMap,
    std::int64_t now, const std::set<std::string>& used)
{
    Decision d;
    const std::string steam = OptionValue(options, "PlayerId");
    const std::string token = OptionValue(options, "HearthIdToken");
    const std::string current = OptionValue(options, "Name");
    if (token.empty()) { d.reason = "no identity token (old app or self-host): unchanged"; return d; }
    if (!IsSteamId(steam)) { d.reason = "no Steam ID in the join: unchanged"; return d; }
    const auto check = VerifyToken(token, key, steam, now, used);
    if (!check.ok) { d.reason = check.reason + ": unchanged"; return d; }
    d.nonce = check.nonce;
    const auto it = steamMap.find(steam);
    if (it == steamMap.end()) { d.reason = "first verified join for this Steam ID: unchanged"; return d; }
    if (it->second == current) { d.reason = "same computer as the first join: unchanged"; return d; }
    d.swap = true;
    d.to = it->second;
    d.reason = "verified Steam ID on a different computer: joins as the first computer's character";
    return d;
}
} // namespace hearth::identity
