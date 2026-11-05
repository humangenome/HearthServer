-- Run from the repository root: lua5.4 tests/join-gate-refusal-write.test.lua [path to IdentityPlugin.cpp]
-- The join password gate must refuse a join only through the game's own FString::operator=(const TCHAR*), never by
-- writing an FString's buffer or fields itself: the engine frees ErrorMessage with its own allocator, and a refusal text
-- from any other heap crashes the whole game on the first wrong password. This reads the plugin source and fails if:
--   1. errorMessage is used for anything but the game's operator=, the read-only empty check and the original call;
--   2. any FStringRaw field (data / num / max) is assigned anywhere;
--   3. the refusal is not set before the game's own PreLogin runs, or the operator= prologue is not build-checked;
--   4. a refused join can still reach the identity swap.
local path = arg[1] or "src/native/Hearth.Identity/src/IdentityPlugin.cpp"
local f = assert(io.open(path, "r"))
local src = f:read("*a")
f:close()

local fails, n = 0, 0
local function check(ok, what)
    n = n + 1
    print((ok and "ok" or "FAIL") .. " - " .. what)
    if not ok then fails = fails + 1 end
end

-- strip // comments so prose about the trap does not count
local code = src:gsub("//[^\n]*", "")

-- 1. every use of errorMessage
local allowed = {
    ["FStringRaw* errorMessage)"] = true,                  -- the hook's parameter list
    ["FStringRaw* errorMessage);"] = true,                 -- the PreLoginFn type
    ["errorMessage && g_fstringAssign"] = true,            -- guard before the game's operator=
    ["g_fstringAssign(errorMessage, kRefusalText)"] = true,
    ["IsEmptyFString(errorMessage)"] = true,
    ["uniqueId, errorMessage);"] = true,                   -- the call to the game's own PreLogin
}
local bad = {}
local _, uses = code:gsub("errorMessage", "")
for line in code:gmatch("[^\n]+") do
    if line:find("errorMessage", 1, true) then
        local s = 1
        while true do
            local a, b = line:find("errorMessage", s, true)
            if not a then break end
            local ok = false
            for pattern in pairs(allowed) do
                local i = line:find(pattern, 1, true)
                if i and i <= a and a <= i + #pattern then ok = true end
            end
            if not ok then bad[#bad + 1] = line:gsub("^%s+", "") end
            s = b + 1
        end
    end
end
check(uses > 0, "the plugin has an errorMessage parameter")
check(#bad == 0, "errorMessage only reaches the game's operator=, the read-only empty check and the game's own PreLogin"
    .. (#bad > 0 and (": " .. table.concat(bad, " | ")) or ""))

-- 2. no FString field writes
local fieldWrites = {}
for line in code:gmatch("[^\n]+") do
    if line:match("[%-%.>]%s*data%s*=[^=]") or line:match("[%-%.>]%s*num%s*=[^=]") or line:match("[%-%.>]%s*max%s*=[^=]") then
        fieldWrites[#fieldWrites + 1] = line:gsub("^%s+", "")
    end
end
check(#fieldWrites == 0, "no FString data/num/max field is written anywhere"
    .. (#fieldWrites > 0 and (": " .. table.concat(fieldWrites, " | ")) or ""))
check(not code:find("errorMessage%-%>") and not code:find("errorMessage%."), "errorMessage is never dereferenced for a write")

-- 3. order and build lock
local hook = code:match("void HookPreLogin%(.-\n}\n")
check(hook ~= nil, "HookPreLogin found")
if hook then
    local setAt = hook:find("g_fstringAssign(errorMessage, kRefusalText)", 1, true)
    local origAt = hook:find("g_originalPreLogin(", 1, true)
    check(setAt and origAt and setAt < origAt, "the refusal is set before the game's own PreLogin runs")
    local identityAt = hook:find("hearth::identity::Decide(", 1, true)
    local gateAt = hook:find("hearth::joingate::Check(", 1, true)
    check(gateAt and identityAt and gateAt < identityAt, "the password is checked before the identity decision")
    local elseAt = hook:find("else", gateAt or 1, true)
    check(elseAt and identityAt and elseAt < identityAt, "the identity decision runs only in the allowed branch")
    check(hook:find("catch (...)", 1, true) ~= nil, "nothing thrown inside the gate reaches the game")
    check(hook:find("refuse = g_gate.mode != hearth::joingate::Mode::Open", 1, true) ~= nil,
        "an error inside the gate refuses the join when a password is set (never fails open)")
end
check(code:find("PrologueMatches(kRvaFStringAssign, kFStringAssignPrologue", 1, true) ~= nil,
    "the game's operator= is build-checked by its prologue before install")
check(code:find("kRvaFStringAssign = 0x0120CF80", 1, true) ~= nil, "operator= is the RVA AMistOasisGameMode::PreLogin calls")
check(code:find('kRefusalText%[%] = L"') ~= nil, "the refusal text is a static wide literal in this module (the game copies it)")

print(string.format("%d/%d passed", n - fails, n))
os.exit(fails == 0 and 0 or 1)
