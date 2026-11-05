-- Run from the repository root: lua5.4 tests/thread-safety-gate.test.lua
-- Checks the thread-safety gate itself (tests/host-thread-safety.test.lua) on small mods written here:
-- two that are safe and that the gate used to reject, and two that are unsafe and must stay rejected.
--
-- 2026-10-25/27 (hearth-gate-parse-flaw): a bigger table constructor in bw_host's main chunk made the
-- gate report 7 background calls into the walls code that do not exist. Cause: luac prints a constant
-- operand with a trailing "k" (SETFIELD 1 2 3k: store constant 3), and the gate read it as register 3,
-- so a table field holding a constant was bound to whatever function sat in register 3 at the time;
-- constants move when a constructor grows, so the false edge came and went with unrelated edits. A
-- second hole of the same kind: an instruction the gate does not model (LOADI, arithmetic, GETI, ...)
-- left the register's old name or function in place, so a later store through it bound the old one.
-- False edges can hide real ones in review noise; both are fixed and pinned here.
-- GATE=<path> runs these against another copy of the gate: the old one fails checks 1, 2 and 5 (it rejects
-- safe mods) and passes 3 and 4 (it still catches real background calls; 4 accepts either name the old and new gate
-- give the function).
local gate = os.getenv("GATE") or "tests/host-thread-safety.test.lua"
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("ok - " .. what) else failures = failures + 1; print("FAIL - " .. what) end
end
local function runGate(name, src)
    local path = os.tmpname() .. "-" .. name .. ".lua"
    local f = assert(io.open(path, "w")); f:write(src); f:close()
    local p = assert(io.popen("lua5.4 " .. gate .. " '" .. path .. "' 2>&1; echo EXIT=$?"))
    local out = p:read("*a"); p:close()
    os.remove(path)
    local code = tonumber(out:match("EXIT=(%d+)%s*$"))
    return code, out
end
local PUMP = "\nLoopInGameThreadWithDelay(1000, function() end)\n"

-- 1. a table field holding a constant (luac: SETFIELD ... 1k) is not bound to the function in register 1
local code, out = runGate("kflag", [[
local s = "v"
local function wallsGameOnly()
    local o = FindFirstOf("Actor")
    o:K2_DestroyActor()
end
local T = { v = "w" }
pcall(T.v)
]] .. PUMP)
check(code == 0, "a constant table field is not taken for the function in the same-numbered register")
if code ~= 0 then io.write(out) end

-- 2. a register overwritten by an instruction the gate does not model forgets the function it held
code, out = runGate("stale", [[
local function gameOnly()
    local o = FindFirstOf("Actor")
    o:K2_DestroyActor()
end
local x = gameOnly
x = 5
local T = {}
T.cb = x
pcall(T.cb)
]] .. PUMP)
check(code == 0, "a register overwritten with a number no longer carries the function it held")
if code ~= 0 then io.write(out) end

-- 3. a real game function call from background code is still caught
code, out = runGate("realbg", [[
LoopAsync(1000, function()
    local o = FindFirstOf("Actor")
    o:K2_DestroyActor()
    return true
end)
]] .. PUMP)
check(code ~= 0 and out:find(":K2_DestroyActor%(%)") ~= nil, "a game function called from LoopAsync is still reported")

-- 4. a function stored in a constructor field and called from background code is still caught
code, out = runGate("ctorcall", [[
local function gameCall()
    local o = FindFirstOf("Actor")
    o:K2_DestroyActor()
end
local T = { cb = gameCall, n = 0, name = "x" }
LoopAsync(1000, function()
    pcall(T.cb)
    return true
end)
]] .. PUMP)
check(code ~= 0 and out:find(":K2_DestroyActor%(%)") ~= nil and (out:find("T%.cb") ~= nil or out:find("gameCall") ~= nil), "a function stored in a constructor field and called from LoopAsync is still reported")

-- 5. the 10/25 shape: a bigger constructor of constants after many local game-only functions (bw_host's
-- GAME_THREAD_WATCH grew this way). Every constant field's operand number lands on a register that holds one of
-- the functions; the old gate binds 8 of the 9 fields to one and reports 5 background calls that do not exist.
local lines = {}
for i = 1, 14 do
    lines[#lines + 1] = string.format("local function wall%d()\n    local o = FindFirstOf(\"Actor\")\n    o:K2_DestroyActor()\nend", i)
end
lines[#lines + 1] = 'local WATCH = { tm = {}, tmSince = 0, tmEvery = 60, inPump = false, lk = 0, label = "gt", window = 61, lines = 0, worst = 0, name = "pump" }'
lines[#lines + 1] = "LoopAsync(1000, function()"
for _, f in ipairs({ "tmSince", "tmEvery", "inPump", "lk", "label", "window", "lines", "worst", "name" }) do
    lines[#lines + 1] = "    pcall(WATCH." .. f .. ")"
end
lines[#lines + 1] = "    return false\nend)"
lines[#lines + 1] = "LoopInGameThreadWithDelay(1000, function()"
for i = 1, 14 do lines[#lines + 1] = string.format("    pcall(wall%d)", i) end
lines[#lines + 1] = "end)"
code, out = runGate("watchctor", table.concat(lines, "\n") .. "\n")
check(code == 0, "a bigger constructor of constants after many local functions binds none of its fields to a function")
if code ~= 0 then io.write(out) end

print(string.format("%d of %d gate checks passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
