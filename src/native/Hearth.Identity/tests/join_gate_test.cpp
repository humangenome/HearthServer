// Run (one line): g++ -std=c++20 -O1 -Wall -Wextra -Werror -I src/native/Hearth.Identity/src
//   src/native/Hearth.Identity/src/IdentityCore.cpp src/native/Hearth.Identity/src/JoinGateCore.cpp
//   src/native/Hearth.Identity/tests/join_gate_test.cpp -o /tmp/join_gate_test && /tmp/join_gate_test
// Checks the join password gate on its own: the digest HearthServer and the gate share, the gate file, the password
// the app sends (?HearthKey=, percent-encoded, trimmed), wrong and missing passwords, and the per-address wait.
#include "JoinGateCore.hpp"

#include <cstdio>
#include <string>

using namespace hearth::joingate;

static int g_fail = 0, g_n = 0;
static void Expect(bool ok, const char* what)
{
    ++g_n;
    std::printf("%s - %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) ++g_fail;
}

// What HearthConnect sends: every byte outside [A-Za-z0-9-_.~] percent-encoded.
static std::string UrlEncode(const std::string& s)
{
    static const char* d = "0123456789ABCDEF";
    std::string o;
    for (unsigned char c : s)
    {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
            o.push_back(static_cast<char>(c));
        else { o.push_back('%'); o.push_back(d[c >> 4]); o.push_back(d[c & 15]); }
    }
    return o;
}

static std::string Join(const std::string& key)
{
    std::string o = "?Name=steam_76561190000000101?PlayerId=76561190000000101?PlatformProvider=STEAM?HearthDisplayName=Tester";
    if (!key.empty()) o += "?HearthKey=" + UrlEncode(key);
    return o;
}

int main()
{
    // shared vectors (HearthServer's JoinGateFileTests use the same three)
    Expect(PasswordDigest("correct horse battery") == "ab166b6e03efd20c411f1d1206e9fcafea2780e8c89d80d7a55a416b8efa03f7",
        "digest vector 1 (plain ASCII)");
    Expect(PasswordDigest("  p\xc3\xa4ssw\xc3\xb6rd \xe2\x82\xac  ") == "396f4a72f23a7b5979765c588e72f32c65d54f2a6dd41825a1879139f47c3335",
        "digest vector 2 (UTF-8, spaces around it trimmed)");
    Expect(PasswordDigest("x") == "c63f268171ab99eab496e56e28078a246e7bae0f8010fdd66d36a994e446fbbe", "digest vector 3 (one character)");
    Expect(TrimPassword(std::string(" \t\r\n\x0B" "a b", 8) + std::string("\0", 1)) == "a b", "trim matches PHP trim(), inner space kept");

    // gate file
    const std::string digest = PasswordDigest("correct horse battery");
    Expect(ParseGateFile("open\r\n").mode == Mode::Open, "file 'open' = open server");
    Expect(ParseGateFile("\xEF\xBB\xBFopen").mode == Mode::Open, "a byte-order mark is ignored");
    Config locked = ParseGateFile("v1 " + digest + "\n");
    Expect(locked.mode == Mode::Locked && locked.digest == digest, "file 'v1 <digest>' = locked");
    std::string upper = digest;
    for (char& c : upper) if (c >= 'a' && c <= 'f') c = static_cast<char>(c - 'a' + 'A');
    Expect(ParseGateFile("v1 " + upper).digest == digest, "upper-case hex is accepted");
    Expect(ParseGateFile("").mode == Mode::Broken, "an empty file refuses every join (never fails open)");
    Expect(ParseGateFile("v1 " + digest.substr(0, 63)).mode == Mode::Broken, "a short digest refuses every join");
    Expect(ParseGateFile("v2 " + digest).mode == Mode::Broken, "an unknown version refuses every join");
    Expect(ParseGateFile("correct horse battery").mode == Mode::Broken, "a plain password in the file is not accepted");

    // addresses
    Expect(AddressKey("203.0.113.7:7777") == "203.0.113.7", "IPv4 with port -> address");
    Expect(AddressKey("203.0.113.7") == "203.0.113.7", "IPv4 alone unchanged");
    Expect(AddressKey("[2001:db8::1]:7777") == "2001:db8::1", "IPv6 with port -> address");
    Expect(AddressKey("2001:db8::1") == "2001:db8::1", "IPv6 alone unchanged");

    // open server: nothing changes, with or without a key
    Limiter lim;
    Expect(Check(Config{}, Join(""), "203.0.113.7", 1000, lim).allow, "open server: a join without a password gets in");
    Expect(Check(Config{}, Join("anything"), "203.0.113.7", 1000, lim).allow, "open server: a join with a stale password gets in");
    Expect(lim.records.empty(), "open server: nothing is counted");

    // broken file
    Expect(!Check(Config{Mode::Broken, ""}, Join("correct horse battery"), "203.0.113.7", 1000, lim).allow,
        "broken file: even the right password is refused");

    // locked server
    Verdict ok = Check(locked, Join("correct horse battery"), "203.0.113.7:1", 1000, lim);
    Expect(ok.allow, "locked: the right password gets in");
    Expect(ok.reason.find("correct") == std::string::npos && ok.reason.find(digest.substr(0, 8)) == std::string::npos,
        "the log line never holds the password or its digest");
    Expect(Check(locked, Join("  correct horse battery "), "203.0.113.7", 1000, lim).allow, "locked: spaces typed around it are trimmed");
    Expect(!Check(locked, Join(""), "203.0.113.7", 1000, lim).allow, "locked: a join without a password is refused");
    Expect(lim.records.empty(), "a missing password is not counted as a guess");
    Expect(!Check(locked, "?Name=x?HearthKey=", "203.0.113.7", 1000, lim).allow, "locked: an empty ?HearthKey= is refused");
    Verdict wrong = Check(locked, Join("Correct horse battery"), "203.0.113.7", 1000, lim);
    Expect(!wrong.allow, "locked: a wrong password is refused (case matters)");
    Expect(wrong.reason.find("Correct") == std::string::npos, "the refusal line never holds the typed password");
    Expect(!Check(locked, "?Name=x?HearthKeyX=correct%20horse%20battery", "203.0.113.7", 1000, lim).allow,
        "locked: a look-alike option name is not the password");
    Config utf = ParseGateFile("v1 " + PasswordDigest("p\xc3\xa4ssw\xc3\xb6rd \xe2\x82\xac"));
    Expect(Check(utf, Join("p\xc3\xa4ssw\xc3\xb6rd \xe2\x82\xac"), "198.51.100.2", 1000, lim).allow,
        "locked: a UTF-8 password sent percent-encoded gets in");

    // the per-address wait: the app's 3 join retries resend the same wrong password; only distinct ones count
    Limiter l2;
    for (int i = 0; i < 9; ++i) Check(locked, Join("typo"), "203.0.113.9", 2000 + i, l2);
    Expect(Check(locked, Join("correct horse battery"), "203.0.113.9", 2010, l2).allow,
        "the same wrong password 9 times (retries) does not lock the player out");
    for (int i = 0; i < 4; ++i) Check(locked, Join("guess" + std::to_string(i)), "203.0.113.9", 3000 + i, l2);
    Expect(Check(locked, Join("correct horse battery"), "203.0.113.9:2", 3005, l2).allow, "4 different wrong passwords: still allowed");
    for (int i = 0; i < 5; ++i) Check(locked, Join("guess" + std::to_string(i)), "203.0.113.9", 4000 + i, l2);
    Verdict waiting = Check(locked, Join("correct horse battery"), "203.0.113.9:3", 4010, l2);
    Expect(!waiting.allow && waiting.reason.find("waiting") != std::string::npos,
        "5 different wrong passwords in 10 min: even the right one waits");
    Expect(Check(locked, Join("correct horse battery"), "203.0.113.10", 4010, l2).allow, "another address is not affected");
    Expect(Check(locked, Join("correct horse battery"), "203.0.113.9", 4004 + kBlockSeconds + 1, l2).allow,
        "after the 10-minute wait the right password gets in");
    Limiter l3;
    for (int i = 0; i < 4; ++i) Check(locked, Join("old" + std::to_string(i)), "203.0.113.11", 5000 + i, l3);
    for (int i = 0; i < 4; ++i) Check(locked, Join("new" + std::to_string(i)), "203.0.113.11", 5000 + kWindowSeconds + i, l3);
    Expect(Check(locked, Join("correct horse battery"), "203.0.113.11", 5000 + kWindowSeconds + 10, l3).allow,
        "guesses older than 10 minutes are forgotten");

    // memory stays bounded under a flood of addresses
    Limiter l4;
    for (int i = 0; i < 3000; ++i) Check(locked, Join("x"), "10.0." + std::to_string(i / 250) + "." + std::to_string(i % 250), 6000 + i, l4);
    Expect(l4.records.size() <= kMaxAddresses, "at most 1024 addresses are remembered");

    std::printf("%d/%d passed\n", g_n - g_fail, g_n);
    return g_fail == 0 ? 0 : 1;
}
