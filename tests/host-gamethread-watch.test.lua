-- Run from the repository root: lua5.4 tests/host-gamethread-watch.test.lua [path/to/bw_host/main.lua]
-- A game-thread callback that UE4SS never runs must not stop a service for good. On 2026-10-12 a server's UE4SS log
-- read "Hook threw exception: ... Ref was not function" / "Freed invalid callbacks"; the callbacks queued then never
-- ran, every service kept its "queued" flag, and the roster, gameplay settings, saves and join help stopped for 58 h.
-- Checks, with a stub UE4SS that can drop callbacks:
--   * a dropped roster callback is given up on after the timeout, its service queues again and the roster is written;
--   * if the dropped callback runs after all, it is skipped and says so;
--   * when nothing runs on the game thread for 5 min, one line says so and the heartbeat shows gt=lost:<n>,stalled.
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua"
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/Logs' '" .. dir .. "/HearthServer'"))
local SERVER_DIR = dir .. "/HearthServer"
local ROSTER = SERVER_DIR .. "\\roster.json"
local LOG = dir .. "/Logs/bw_host.log"
local NOW = 1791600000
local ENV = { HEARTH_HOST_LOG = LOG, HEARTH_SERVER_DIR = SERVER_DIR }
local stubOs = setmetatable({
    time = function(t) if t then return os.time(t) end return NOW end,
    getenv = function(k) return ENV[k] end,
}, { __index = os })

local function uobj(addr, name, fields)
    local o = fields or {}
    o.__addr, o.__name = addr, name
    function o:IsValid() return true end
    function o:GetAddress() return self.__addr end
    function o:GetFullName() return self.__name end
    function o:GetFName()
        local short = self.__name:match("([^%.]+)$")
        return { ToString = function() return short end }
    end
    return o
end
local LEVEL = "/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08:PersistentLevel."
local conns = { GetArrayNum = function(self) return #self end }
local driver = uobj(9000, "IpNetDriver /Engine/Transient.IpNetDriver_0", { ClientConnections = conns })
local world = uobj(9500, "World /Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08", { NetDriver = driver })
local session = uobj(8100, "MistOasisGameSession_C " .. LEVEL .. "MistOasisGameSession_C_0", { MaxPlayers = 5 })
local gm = uobj(8000, "BP_MistOasisGameMode_C " .. LEVEL .. "BP_MistOasisGameMode_C_0",
    { NumPlayers = 2, NumTravellingPlayers = 0, NumSpectators = 0, GameSession = session })
local pcs = {}

local dropping, dropped = false, {}
local noop = function() return nil end
local env = setmetatable({
    os = stubOs,
    LoopAsync = noop, ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = noop, RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback) if dropping then dropped[#dropped + 1] = callback else callback() end end,
    FindAllOf = function(name)
        if name == "IpNetDriver" then return { driver } end
        if name == "World" then return { world } end
        if name == "PlayerController" then return pcs end
        if name == "GameModeBase" then return { gm } end
        return {}
    end,
    FindFirstOf = function(name) if name == "World" then return world end return nil end,
    StaticFindObject = noop, print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })
local exports = "\nreturn { serviceJoiners = serviceJoiners, netDriverValid = netDriverValid }\n"
local mod = assert(load(source .. exports, "main.lua", "t", env))()

local function controller(addr, serial, opts)
    opts = opts or {}
    local ps = uobj(addr + 1, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_" .. serial,
        { bOnlySpectator = false, GetPlayerName = function() return opts.name or "Player" end })
    return uobj(addr, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_" .. serial,
        { PlayerState = ps, IsLocalPlayerController = function() return opts.host or false end })
end
local function readFile(p) local f = io.open(p, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function count(text, needle) local n, i = 0, 1; while true do local a, b = (text or ""):find(needle, i, true); if not a then return n end; n, i = n + 1, b + 1 end end

local passed, failed = 0, 0
local function check(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("ok - " .. name) else failed = failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end

local hostPc = controller(1100, 20, { host = true })
local hal = controller(1200, 21, { name = "Hal" })
hal.Pawn = uobj(1300, "Player_C " .. LEVEL .. "Player_C_21")
pcs[1], pcs[2] = hostPc, hal
local f = assert(io.open(SERVER_DIR .. "\\login-identities.tsv", "w"))
f:write(table.concat({ tostring(NOW * 1000), "", "steam_76561198000000051", "steam_76561198000000051", "Hal", "", "" }, "\t"), "\n")
f:close()
conns[1] = uobj(9200, "IpConnection /Engine/Transient.IpConnection_21", { OwningActor = hal })
mod.netDriverValid()
local W = env.GAME_THREAD_WATCH

check("the mod watches its game-thread callbacks", function()
    assert(type(W) == "table" and type(W.check) == "function", "no GAME_THREAD_WATCH in this mod")
end)

check("a dropped roster callback is given up on after the timeout and the roster is written again", function()
    for t = 10, 22, 3 do mod.serviceJoiners(t) end  -- warm up: identities, roster
    os.remove(ROSTER)
    dropping = true
    mod.serviceJoiners(30)                          -- this pass's roster callback is lost
    dropping = false
    assert(#dropped >= 1, "nothing was dropped")
    for t = 33, 90, 3 do NOW = NOW + 3; mod.serviceJoiners(t) end
    assert(readFile(ROSTER) == nil, "roster written while its flag was stuck (the drop did not take)")
    NOW = NOW + W.timeout
    W.check()
    assert(count(readFile(LOG), "game-thread callback lost label=write-roster") == 1, "no 'lost' line")
    mod.serviceJoiners(93)
    local roster = readFile(ROSTER)
    assert(roster and roster:find('"players":[{', 1, true), "roster not written after the give-up: " .. tostring(roster))
end)

check("a given-up callback that runs after all is skipped and logged", function()
    local before = count(readFile(LOG), "ran after it was given up on")
    for _, cb in ipairs(dropped) do cb() end
    dropped = {}
    assert(count(readFile(LOG), "ran after it was given up on label=write-roster") == before + 1, "late run not logged")
end)

check("nothing running on the game thread for 5 minutes is said once and shown on the heartbeat", function()
    dropping = true
    for t = 96, 400, 3 do NOW = NOW + 3; mod.serviceJoiners(t); W.check() end
    NOW = NOW + 400
    W.check(); W.check()
    local text = readFile(LOG)
    assert(count(text, "game-thread callbacks are not running") == 1, "stall line count " .. count(text, "game-thread callbacks are not running"))
    assert(W.info():find("gt=lost:", 1, true) and W.info():find("stalled", 1, true), "heartbeat info '" .. W.info() .. "'")
    dropping = false
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
