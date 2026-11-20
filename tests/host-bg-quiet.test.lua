-- Run from the repository root: lua5.4 tests/host-bg-quiet.test.lua [path/to/bw_host/main.lua]
-- Loads the whole host mod against a stub UE4SS and drives its 1.5 s background service loop (the
-- LoopAsync body) round by round. v0.18.65: while bw_pause's status file says the world is paused with
-- nobody connected, the loop must stop walking every object for the player controllers each round
-- (every 10th round only) and must not run the Travel Sign service; everything else keeps its cadence.
-- Checks:
--   * a running world walks for the controllers every round (unchanged);
--   * a fresh paused status (paused=1, connections=0) makes the loop quiet: 1 walk in 10 rounds, no
--     Travel Sign search, the heartbeat line still written every 6 rounds and still last-field ",stalled"-safe;
--   * the loop is back in full the round the status says paused=0, or connections>0, or the status is
--     older than 150 s, or the file is missing or half-written, or Logs\bw_bgquiet.off exists;
--   * the "bg" timing line is written once a minute after host-up.
--   * v0.18.69: with nobody connected on the listen world's net driver the controllers are walked on heartbeat rounds
--     only (1 round in 6); a client connection brings the walk back every round from the next round; with the switch
--     off (HEARTH_BG_QUIET=0) every round, as before.
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua"
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/Logs' '" .. dir .. "/HearthServer'"))
local SERVER_DIR = dir .. "/HearthServer"
local LOG = dir .. "/Logs/bw_host.log"
local STATUS = dir .. "/Logs\\bw_pause.status" -- the mod joins with a backslash
local OFF = dir .. "/Logs\\bw_bgquiet.off"
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
local world = uobj(9500, "World " .. LEVEL:gsub(":PersistentLevel%.$", ""), { NetDriver = driver, TimeSeconds = 100 })
local viewport = uobj(9600, "GameViewportClient /Engine/Transient.GameEngine_0:GameViewportClient_0", { bDisableWorldRendering = false })
local engine = uobj(9700, "GameEngine /Engine/Transient.GameEngine_0", { GameViewport = viewport })
local gi = uobj(9750, "BP_MistGameInstance_C /Engine/Transient.GameEngine_0:BP_MistGameInstance_C_0")
local session = uobj(8100, "MistOasisGameSession_C " .. LEVEL .. "MistOasisGameSession_C_0", { MaxPlayers = 5 })
local gm = uobj(8000, "BP_MistOasisGameMode_C " .. LEVEL .. "BP_MistOasisGameMode_C_0",
    { NumPlayers = 1, NumTravellingPlayers = 0, NumSpectators = 0, GameSession = session })
local hostPs = uobj(1101, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_20", { bOnlySpectator = false, PlayerNamePrivate = "Host" })
local hostPc = uobj(1100, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_20",
    { PlayerState = hostPs, Player = LOCAL_PLAYER, IsLocalPlayerController = function() return true end })
local pcs = { hostPc }

local walks = {}
local function walked(name) return walks[name] or 0 end
local noop = function() return nil end
local gtPump = nil
local loops = {}
local env = setmetatable({
    LoopInGameThreadAfterFrames = function(_, callback) gtPump = callback end,
    os = stubOs,
    LoopAsync = function(ms, callback) loops[#loops + 1] = { ms = ms, cb = callback } end,
    ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = noop, RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback) callback() end,
    FindAllOf = function(name)
        walks[name] = (walks[name] or 0) + 1
        if name == "IpNetDriver" then return { driver } end
        if name == "World" then return { world } end
        if name == "GameViewportClient" then return { viewport } end
        if name == "PlayerController" then return pcs end
        if name == "GameModeBase" then return { gm } end
        return {}
    end,
    FindFirstOf = function(name)
        if name == "GameEngine" then return engine end
        if name == "World" then return world end
        if name == "GameInstance" then return gi end
        return nil
    end,
    StaticFindObject = noop, print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })

assert(load(source, "main.lua", "t", env))()
local mainLoop = nil
for _, l in ipairs(loops) do if l.ms == 1500 then mainLoop = l.cb end end
assert(mainLoop, "no 1.5 s LoopAsync service loop registered")
if gtPump then gtPump() end -- the first frame: boot steps

-- one service round: the background body, then a game-thread frame; 1.5 s of the loop's clock pass
local function round()
    mainLoop()
    if gtPump then gtPump() end
    NOW = NOW + 2
end
local function readFile(p)
    local f = io.open(p, "r"); if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end
local function writeFile(p, s)
    local f = assert(io.open(p, "w")); f:write(s); f:close()
end
local function status(paused, connections, updated)
    writeFile(STATUS, string.format("paused=%d\r\nsince=%d\r\nenabled=1\r\nconnections=%s\r\npauses=1\r\nupdated=%d\r\nwhy=test\r\n",
        paused, NOW - 300, tostring(connections), updated or NOW))
end
local function count(s, needle)
    local n, i = 0, 1
    while true do
        local a = s:find(needle, i, true)
        if not a then return n end
        n, i = n + 1, a + #needle
    end
end

local passed, failed = 0, 0
local function check(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end

-- boot: settle, host, "listen server UP"
for _ = 1, 40 do round() end
check("the loop reaches host-up against the stub engine", function()
    assert(readFile(LOG):find("listen server UP", 1, true), "no host-up line")
end)
-- past the Travel Sign startup scan window (8 passes, 60 s apart on the loop clock)
for _ = 1, 360 do round() end

local CLIENT = uobj(9300, "IpConnection /Engine/Transient.IpConnection_9", {})
check("v0.18.69: a running world with nobody connected walks for the controllers on heartbeat rounds only", function()
    os.remove(STATUS)
    walks = {}
    for _ = 1, 30 do round() end
    assert(walked("PlayerController") == 5, "controller walks in 30 rounds: " .. walked("PlayerController") .. " (v0.18.68: 30)")
    local log = readFile(LOG)
    assert(log:find("PCs=1 remote=0 seats=", 1, true), "heartbeat without the seat check")
end)

check("v0.18.69: a client connection on the net driver brings the controller walk back every round", function()
    conns[1] = CLIENT
    walks = {}
    for _ = 1, 30 do round() end
    conns[1] = nil
    assert(walked("PlayerController") == 30, "controller walks with a connection: " .. walked("PlayerController"))
end)

check("v0.18.69: with the switch off (HEARTH_BG_QUIET=0 or Logs\\bw_bgquiet.off) the controllers are walked every round", function()
    local B = rawget(env, "BG_LOOP")
    B.enabled = false
    walks = {}
    for _ = 1, 12 do round() end
    B.enabled = true
    assert(walked("PlayerController") == 12, "controller walks with the switch off: " .. walked("PlayerController"))
    writeFile(OFF, "off")
    walks = {}
    for _ = 1, 12 do round() end
    os.remove(OFF)
    assert(walked("PlayerController") == 12, "controller walks with Logs\\bw_bgquiet.off: " .. walked("PlayerController"))
end)

check("a fresh paused status makes the loop quiet: 1 controller walk in 10 rounds, no Travel Sign search", function()
    status(1, 0)
    round() -- the round that reads the status and says so
    assert(readFile(LOG):find("background loop quiet", 1, true), "no quiet line")
    walks = {}
    local hbBefore = count(readFile(LOG), "] hb t=")
    for _ = 1, 60 do status(1, 0); round() end
    assert(walked("PlayerController") == 6, "controller walks in 60 quiet rounds: " .. walked("PlayerController"))
    -- the seat check (one more walk) runs only on a safety-net round that is also a heartbeat round (every 30th)
    assert(walked("GameModeBase") == 2, "seat-check walks in 60 quiet rounds: " .. walked("GameModeBase"))
    assert(walked("MistMapIconProviderComponent") == 0 and walked("MistFastTravelComponent") == 0, "Travel Sign search while quiet")
    local log = readFile(LOG)
    local hb = count(log, "] hb t=") - hbBefore
    assert(hb == 10, "heartbeat lines in 60 quiet rounds: " .. hb)
    -- 8 quiet heartbeats and 2 from safety-net rounds (full: seats=); the field order is unchanged
    assert(count(log, "PCs=1 remote=0 quiet | TICKRATE") == 8, "quiet heartbeats: " .. count(log, "PCs=1 remote=0 quiet"))
end)

check("the roster is still written while quiet", function()
    os.remove(SERVER_DIR .. "\\roster.json")
    for _ = 1, 12 do status(1, 0); round() end
    assert(readFile(SERVER_DIR .. "\\roster.json"):find('"players":[]', 1, true), "no idle roster while quiet")
end)

local function backInFull(label, setup)
    check(label, function()
        status(1, 0); round(); walks = {}
        local fullBefore = count(readFile(LOG), "background loop in full")
        setup()
        round()
        assert(count(readFile(LOG), "background loop in full") == fullBefore + 1, "no 'in full' line")
        walks = {}
        conns[1] = CLIENT   -- v0.18.69: with nobody connected a running world walks on heartbeat rounds only
        for _ = 1, 10 do round() end
        conns[1] = nil
        assert(walked("PlayerController") == 10, "controller walks after " .. label .. ": " .. walked("PlayerController"))
        os.remove(OFF)
    end)
end
backInFull("back in full when the status says the world runs again (paused=0)", function() status(0, 1) end)
backInFull("back in full when a client is connected", function() status(1, 1) end)
backInFull("back in full when the status is older than 150 s", function() status(1, 0, NOW - 400) end)
backInFull("back in full when the status file is missing", function() os.remove(STATUS) end)
backInFull("back in full when the status file is half-written", function() writeFile(STATUS, "paused=1\r\nsince=") end)
backInFull("back in full when Logs\\bw_bgquiet.off exists", function() status(1, 0); writeFile(OFF, "off") end)
-- v0.18.69 (Security, 2026-11-15): the owner can write the Logs folder; the status file is read 512 bytes at most, and a
-- longer file (here a valid paused status with a long why= line) or one that does not parse means not paused.
backInFull("back in full when the status file is over 512 bytes, even if it reads as paused", function()
    writeFile(STATUS, string.format("paused=1\r\nsince=%d\r\nenabled=1\r\nconnections=0\r\npauses=1\r\nupdated=%d\r\nwhy=%s\r\n",
        NOW - 300, NOW, string.rep("x", 600)))
end)
backInFull("back in full when the status file does not parse", function() writeFile(STATUS, string.rep("\0garbage ", 40)) end)

check("the bg timing line is written once a minute after host-up", function()
    local before = count(readFile(LOG), "] bg ")
    for _ = 1, 31 do round() end -- 62 s of the stub clock
    local log = readFile(LOG)
    assert(count(log, "] bg ") > before, "no bg line")
    assert(log:find("bg %d+s: rounds=%d+ quiet=%d+ busy_ms=%d+") , "bg line shape")
end)

-- v0.18.69 re-lab (2026-11-15 13:37-13:44): paused with nobody on, the safety-net walk ran 0 times in 7 minutes. The
-- no-connection rule (walk on heartbeat rounds only, every 6th) was applied on top of the every-10th safety net, and with
-- the two counts out of step no round was both. Whatever the step, every 10th quiet round walks.
check("v0.18.69: while quiet the safety-net round walks every 10th round, whatever the heartbeat count's step", function()
    for shift = 1, 6 do
        for _ = 1, shift do status(0, 1); round() end   -- running a few rounds: the heartbeat count moves on
        status(1, 0); round()                            -- quiet again: the safety-net count starts at 0
        walks = {}
        for _ = 1, 60 do status(1, 0); round() end
        assert(walked("PlayerController") == 6, "shift " .. shift .. ": controller walks in 60 quiet rounds: " .. walked("PlayerController"))
    end
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
