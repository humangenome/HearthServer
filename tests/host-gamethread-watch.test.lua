-- Run from the repository root: lua5.4 tests/host-gamethread-watch.test.lua [path/to/bw_host/main.lua]
-- v0.18.61: the host mod's game-thread work runs from one game-thread pump. Background code only
-- appends to a plain Lua queue; it never calls UE4SS's ExecuteInGameThread (in UE4SS b50986bd that call
-- writes to the Lua stack the game thread runs on with nothing locking the two, which left the queue
-- dead for whole sessions with "Ref was not function" and crashed the game: 2026-10-12 on one server,
-- 11 of 54 sessions 10/16-10/18). Checks, with a stub UE4SS:
--   * the mod registers exactly one pump (LoopInGameThreadAfterFrames, every frame) and never calls
--     ExecuteInGameThread; NotifyOnNewObject is registered in the pump's first run, not at load;
--   * work queued by the service loop runs on the next pump run, in order, and the roster is written;
--   * a failing callback is logged, its onError runs, and the next callback still runs;
--   * a callback queued while the pump runs waits for the next run;
--   * when the pump has not run for 60 s one line says so and the heartbeat ends ",stalled" (the
--     panel's Stop reads that); when it runs again one line says so and the heartbeat is clean.
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
local LOCAL_PLAYER = uobj(9800, "LocalPlayer /Engine/Transient.GameEngine_0:LocalPlayer_0")
LOCAL_PLAYER.GetClass = function() return { GetFName = function() return { ToString = function() return "LocalPlayer" end } end } end
local LEVEL = "/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08:PersistentLevel."
local conns = { GetArrayNum = function(self) return #self end }
local driver = uobj(9000, "IpNetDriver /Engine/Transient.IpNetDriver_0", { ClientConnections = conns })
local world = uobj(9500, "World /Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08", { NetDriver = driver })
local session = uobj(8100, "MistOasisGameSession_C " .. LEVEL .. "MistOasisGameSession_C_0", { MaxPlayers = 5 })
local gm = uobj(8000, "BP_MistOasisGameMode_C " .. LEVEL .. "BP_MistOasisGameMode_C_0",
    { NumPlayers = 2, NumTravellingPlayers = 0, NumSpectators = 0, GameSession = session })
local pcs = {}

local noop = function() return nil end
local pump, pumpRegistrations, pumpFrames, eigtCalls, notifyAtLoad, notifyFromPump = nil, 0, nil, 0, 0, 0
local inPump, loaded = false, false
local env = setmetatable({
    LoopInGameThreadAfterFrames = function(frames, callback) pumpRegistrations = pumpRegistrations + 1; pumpFrames = frames; pump = callback end,
    os = stubOs,
    LoopAsync = noop, ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = function()
        if inPump then notifyFromPump = notifyFromPump + 1 elseif not loaded then notifyAtLoad = notifyAtLoad + 1 end
    end,
    RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function() eigtCalls = eigtCalls + 1 end,
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
local exports = "\nreturn { serviceJoiners = serviceJoiners, netDriverValid = netDriverValid, queue = executeInGameThreadSafe }\n"
local mod = assert(load(source .. exports, "main.lua", "t", env))()
loaded = true
local function frame() inPump = true; pump(); inPump = false end

local function controller(addr, serial, opts)
    opts = opts or {}
    local ps = uobj(addr + 1, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_" .. serial,
        { bOnlySpectator = false, PlayerNamePrivate = opts.name or "Player", GetPlayerName = function() return opts.name or "Player" end })
    return uobj(addr, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_" .. serial,
        { PlayerState = ps, Player = (opts.host or false) and LOCAL_PLAYER or nil, IsLocalPlayerController = function() return opts.host or false end })
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

check("one pump, every frame, registered last; no ExecuteInGameThread; hooks registered from the pump", function()
    assert(type(W) == "table" and type(W.check) == "function", "no GAME_THREAD_WATCH in this mod")
    assert(pumpRegistrations == 1 and pumpFrames == 1 and type(pump) == "function", "pump registrations " .. pumpRegistrations)
    assert(W.started == true, "the mod did not record the pump as started")
    assert(notifyAtLoad == 0, notifyAtLoad .. " NotifyOnNewObject call(s) at load (start-up thread)")
    frame()
    assert(notifyFromPump > 0, "NotifyOnNewObject was not registered from the pump's first run")
    assert(count(readFile(LOG), "game-thread pump running (boot steps") == 1, "no boot line")
end)

check("work queued by the service loop runs on the next pump run and the roster is written", function()
    os.remove(ROSTER)
    for t = 10, 22, 3 do mod.serviceJoiners(t) end
    assert(readFile(ROSTER) == nil, "the roster was written off the game thread")
    assert(W.n > 0, "nothing queued")
    frame()
    assert(W.n == 0, "queue not drained: " .. W.n)
    local roster = readFile(ROSTER)
    assert(roster and roster:find('"players":[{', 1, true), "roster not written by the pump: " .. tostring(roster))
    assert(eigtCalls == 0, "ExecuteInGameThread called " .. eigtCalls .. " time(s)")
end)

check("a failing callback is logged, its onError runs, and the next one still runs", function()
    local order, errSeen = {}, nil
    mod.queue("t-first", function() order[#order + 1] = 1 end)
    mod.queue("t-boom", function() error("boom") end, function(e) errSeen = e end)
    mod.queue("t-last", function() order[#order + 1] = 3 end)
    frame()
    assert(#order == 2 and order[1] == 1 and order[2] == 3, "order " .. table.concat(order, ","))
    assert(errSeen and tostring(errSeen):find("boom", 1, true), "onError not run")
    assert(count(readFile(LOG), "game-thread callback failed label=t-boom") == 1, "failure not logged")
end)

check("a callback queued while the pump runs waits for the next run", function()
    local ran = {}
    mod.queue("t-outer", function()
        ran[#ran + 1] = "outer"
        mod.queue("t-inner", function() ran[#ran + 1] = "inner" end)
    end)
    frame()
    assert(#ran == 1 and ran[1] == "outer", "after one run: " .. table.concat(ran, ","))
    frame()
    assert(#ran == 2 and ran[2] == "inner", "after two runs: " .. table.concat(ran, ","))
end)

check("a pump that stops for 60 s is said once and shown on the heartbeat; recovery is said once", function()
    frame()
    assert(W.info() == "", "heartbeat suffix while running: '" .. W.info() .. "'")
    for _ = 1, 30 do NOW = NOW + 3; mod.serviceJoiners(0); W.check() end
    local text = readFile(LOG)
    assert(count(text, "game-thread pump is not running") == 1, "stall line count " .. count(text, "game-thread pump is not running"))
    assert(W.info():find(",stalled", 1, true), "heartbeat info '" .. W.info() .. "'")
    frame()
    W.check(); W.check()
    text = readFile(LOG)
    assert(count(text, "game-thread pump running again after") == 1, "no recovery line")
    assert(W.info() == "", "heartbeat suffix after recovery: '" .. W.info() .. "'")
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
