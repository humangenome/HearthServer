-- Run from the repository root: lua5.4 tests/host-start-minutes.test.lua [path/to/bw_host/main.lua] [--report]
-- The timing harness for bw_host's first minutes after a start and for its background loop, measured in walks (one
-- walk of every object for one class) and lookups by path, the two costs the "gt" and "bg" lines show on a real server.
-- It loads the whole host mod against a stub UE4SS and drives its 1.5 s background loop round by round, with a game
-- frame after each round, replaying what the 2026-11-15 re-lab of v0.18.68 on our test server saw:
--   * 2,394 map-icon providers at host-up, 38 of them with no owner yet; those 38 are gone about 190 s after host-up;
--   * about 20 new providers a minute from the construction hook, each with an owner;
--   * no Travel Sign on that test server's map, so no repairs;
--   * nobody connected, then one player connected and in the world.
-- Measured there (v0.18.68): 7-9 walks a minute on the game thread in minutes 2-4 (about 54 ms each, 460-563 ms a
-- minute for the Travel Sign service); the background loop 40 controller walks a minute with nobody on (about 2.5 s)
-- and 6.2-6.4 s a minute with one player.
-- Checks (v0.18.69):
--   * start minutes, nobody on: at most 1 game-thread walk in any minute and no lookup by path (under ~150 ms a minute
--     with the other game-thread work, about 45 ms);
--   * the 38 waiting providers are dropped once gone, and every arrival is checked;
--   * the background loop, nobody connected: a controller walk on heartbeat rounds only (7 a minute, was 40);
--   * the background loop, one player in the world: no walk of every net driver to find his connection (was one a
--     round), and still a controller walk every round.
-- --report prints the minute-by-minute counts and the cost they stand for at the lab's per-walk cost.
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path, report = "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua", false
for _, a in ipairs(arg) do
    if a == "--report" then report = true else path = a end
end
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local WALK_MS, LOOKUP_MS, PASS_MS, OTHER_GT_MS = 54, 55, 12, 45   -- lab 2026-11-15 (gt lines, minutes 2-4 and paused)

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/Logs' '" .. dir .. "/HearthServer'"))
local SERVER_DIR = dir .. "/HearthServer"
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
local function classed(o, names)
    local chain = {}
    for i, n in ipairs(names) do
        chain[i] = { IsValid = function() return true end, GetFName = function() return { ToString = function() return n end } end }
    end
    for i = 1, #chain do
        local nxt = chain[i + 1]
        chain[i].GetSuperStruct = function() return nxt end
    end
    o.GetClass = function() return chain[1] end
    return o
end
local LOCAL_PLAYER = uobj(9800, "LocalPlayer /Engine/Transient.GameEngine_0:LocalPlayer_0")
LOCAL_PLAYER.GetClass = function() return { GetFName = function() return { ToString = function() return "LocalPlayer" end } end } end
local NET_CONNECTION = { IsValid = function() return true end, GetFName = function() return { ToString = function() return "IpConnection" end } end }

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

-- the map-icon providers
local providers = {}
local nextAddr = 100000
local function addProvider(ownerClass, withOwner)
    nextAddr = nextAddr + 10
    local n = nextAddr
    local owner = classed(uobj(n, ownerClass .. " " .. LEVEL .. ownerClass .. "_" .. n), { ownerClass })
    local prov = classed(uobj(n + 2, "MistMapIconProviderComponent " .. LEVEL .. ownerClass .. "_" .. n .. ".MapIcon", {}),
        { "MistMapIconProviderComponent", "ActorComponent" })
    prov.ownerNow = withOwner and owner or nil
    prov.GetOwner = function(self) return self.ownerNow end
    providers[#providers + 1] = prov
    return prov
end
local waiting = {}
for _ = 1, 2394 - 38 do addProvider("BP_Npc_C", true) end
for i = 1, 38 do waiting[i] = addProvider("BP_Camp_C", false) end

local onGameThread = false
local gt, bg = {}, {}       -- walks by class, this minute
local gtLookups, bgLookups = 0, 0
local gtWalkPasses = 0       -- game frames that made at least one Travel Sign walk
local hooks = {}
local noop = function() return nil end
local gtPump = nil
local loops = {}
local env = setmetatable({
    LoopInGameThreadAfterFrames = function(_, callback) gtPump = callback end,
    os = stubOs,
    LoopAsync = function(ms, callback) loops[#loops + 1] = { ms = ms, cb = callback } end,
    ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = function(p, callback) hooks[p] = callback end,
    RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback)
        local was = onGameThread
        onGameThread = true
        callback()
        onGameThread = was
    end,
    FindAllOf = function(name)
        local t = onGameThread and gt or bg
        t[name] = (t[name] or 0) + 1
        if name == "IpNetDriver" then return { driver } end
        if name == "World" then return { world } end
        if name == "GameViewportClient" then return { viewport } end
        if name == "PlayerController" then return pcs end
        if name == "GameModeBase" then return { gm } end
        if name == "MistMapIconProviderComponent" then return providers end
        return {}
    end,
    FindFirstOf = function(name)
        if name == "GameEngine" then return engine end
        if name == "World" then return world end
        if name == "GameInstance" then return gi end
        return nil
    end,
    StaticFindObject = function(p)
        -- the Travel Sign and connection lookups by path (the gt line's "lookups path="); other code's lookups are cheap
        if type(p) == "string" and (p:find("MapIcon", 1, true) or p:find("FastTravel", 1, true) or p:find("PersistentLevel", 1, true)) then
            if onGameThread then gtLookups = gtLookups + 1 else bgLookups = bgLookups + 1 end
        end
        return nil
    end,
    print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })

assert(load(source, "main.lua", "t", env))()
local mainLoop = nil
for _, l in ipairs(loops) do if l.ms == 1500 then mainLoop = l.cb end end
assert(mainLoop, "no 1.5 s LoopAsync service loop registered")
local function frame()
    if not gtPump then return end
    local before = (gt.MistMapIconProviderComponent or 0) + (gt.MistFastTravelComponent or 0)
    onGameThread = true
    gtPump()
    onGameThread = false
    if (gt.MistMapIconProviderComponent or 0) + (gt.MistFastTravelComponent or 0) > before then gtWalkPasses = gtWalkPasses + 1 end
end
frame() -- the first frame: boot steps, hooks registered

local rounds = 0
local function round()
    mainLoop()
    frame()
    rounds = rounds + 1
    NOW = NOW + (rounds % 2 == 0 and 2 or 1)   -- 1.5 s a round on the wall clock too
end
local function readFile(p)
    local f = io.open(p, "r"); if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end
local function sum(t) local n = 0; for _, v in pairs(t) do n = n + v end; return n end
local function resetMinute() gt, bg, gtLookups, bgLookups, gtWalkPasses = {}, {}, 0, 0, 0 end

local passed, failed = 0, 0
local function check(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end

-- boot to "listen server UP"
local upRound = nil
for _ = 1, 60 do
    round()
    if not upRound and readFile(LOG):find("listen server UP", 1, true) then upRound = rounds end
end
check("the loop reaches host-up against the stub engine", function() assert(upRound, "no host-up line") end)
local function sinceUp() return (rounds - (upRound or 0)) * 1.5 end

-- minutes 1-6 after host-up, nobody on, 20 arrivals a minute, the 38 waiting providers gone at about 190 s
local minutes = {}
local arrivals, arrived = 0, {}
local hook = hooks["/Script/Mist.MistMapIconProviderComponent"]
local function playMinute(extra)
    resetMinute()
    for _ = 1, 40 do
        round()
        if rounds % 2 == 0 and hook then
            local p = addProvider("BP_Wolf_C", true)
            arrivals = arrivals + 1
            arrived[#arrived + 1] = p
            hook(p)
        end
        if sinceUp() >= 190 and #waiting > 0 then
            local gone = {}
            for _, p in ipairs(waiting) do gone[p] = true end
            for i = #providers, 1, -1 do if gone[providers[i]] then table.remove(providers, i) end end
            waiting = {}
        end
        if extra then extra() end
    end
    local m = {
        gtWalks = sum(gt) - (gt.PlayerController or 0) - (gt.IpNetDriver or 0) - (gt.World or 0) - (gt.GameModeBase or 0)
            - (gt.GameViewportClient or 0),
        gtLookups = gtLookups, passes = gtWalkPasses,
        bgPC = bg.PlayerController or 0, bgND = bg.IpNetDriver or 0, bgAll = sum(bg), bgLookups = bgLookups,
    }
    m.tsMs = m.gtWalks * WALK_MS + m.gtLookups * LOOKUP_MS + m.passes * PASS_MS
    m.gtMs = m.tsMs + OTHER_GT_MS
    return m
end
for i = 1, 6 do minutes[i] = playMinute() end

-- every arrival and every waiting provider is settled 3 minutes after the last arrival
local function bgState() return rawget(env, "BG_LOOP").sg or {} end
local tailMinutes = {}
local savedHook = hook
hook = nil
for i = 1, 3 do tailMinutes[i] = playMinute() end
local tailPending = bgState().pending or 0
hook = savedHook

-- one player connected and in the world
local remotePs = uobj(1201, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_21",
    { bOnlySpectator = false, PlayerNamePrivate = "Hal", GetPlayerName = function() return "Hal" end })
local remotePawn = classed(uobj(1300, "Player_C " .. LEVEL .. "Player_C_21"), { "Player_C", "MistPlayer", "Character", "Pawn" })
local remotePc = uobj(1200, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_21",
    { PlayerState = remotePs, Pawn = remotePawn, Player = classed(uobj(9201, "IpConnection /Engine/Transient.IpConnection_21"), { "IpConnection" }),
      IsLocalPlayerController = function() return false end })
local idf = assert(io.open(SERVER_DIR .. "\\login-identities.tsv", "w"))
idf:write(table.concat({ tostring(NOW * 1000), "", "steam_76561198000000051", "steam_76561198000000051", "Hal", "", "" }, "\t"), "\n")
idf:close()
conns[1] = uobj(9202, "IpConnection /Engine/Transient.IpConnection_21", { OwningActor = remotePc, PlayerController = remotePc })
pcs[2] = remotePc
gm.NumPlayers = 2
local playerMinutes = {}
for i = 1, 2 do playerMinutes[i] = playMinute() end
local possessed = readFile(LOG):find("JOINER POSSESSED", 1, true) ~= nil

-- the player leaves; nobody connected again
conns[1] = nil
pcs[2] = nil
gm.NumPlayers = 1
local afterMinutes = {}
for i = 1, 2 do afterMinutes[i] = playMinute() end

-- after the startup scan, nobody on, 20 arrivals a minute (the hooks alone queue providers from here)
local scanDone, scanDoneMinute = false, nil
for _ = 1, 30 do
    if readFile(LOG):find("travel sign discovery startup scan complete", 1, true) then
        scanDone, scanDoneMinute = true, math.floor(sinceUp() / 60); break
    end
    playMinute()
end
local lateMinutes = {}
for i = 1, 3 do lateMinutes[i] = playMinute() end

if report then
    print(string.format("%-14s %8s %8s %7s %8s %9s | %8s %8s %8s", "minute", "gt walks", "lookups", "passes", "TS ms", "gt ms", "bg PC", "bg ND", "bg ms"))
    local function row(label, m)
        print(string.format("%-14s %8d %8d %7d %8d %9d | %8d %8d %8d", label, m.gtWalks, m.gtLookups, m.passes, m.tsMs, m.gtMs,
            m.bgPC, m.bgND, (m.bgAll + m.bgLookups) * 60))
    end
    for i, m in ipairs(minutes) do row("start " .. i, m) end
    for i, m in ipairs(tailMinutes) do row("no arrivals " .. i, m) end
    for i, m in ipairs(playerMinutes) do row("player " .. i, m) end
    for i, m in ipairs(afterMinutes) do row("after " .. i, m) end
    for i, m in ipairs(lateMinutes) do row("late " .. i, m) end
    print("arrivals " .. arrivals .. ", pending after the tail " .. tostring(tailPending) .. ", possessed " .. tostring(possessed)
        .. ", startup scan done by minute " .. tostring(scanDoneMinute))
end

check("v0.18.69: start minutes, nobody on: at most 1 game-thread walk a minute and no lookup by path", function()
    for i = 2, 6 do
        local m = minutes[i]
        assert(m.gtLookups == 0, "minute " .. i .. ": " .. m.gtLookups .. " lookups by path")
        assert(m.gtWalks <= 1, "minute " .. i .. ": " .. m.gtWalks .. " walks (lab v0.18.68: 7-9)")
        assert(m.gtMs < 150, "minute " .. i .. ": about " .. m.gtMs .. " ms")
    end
end)

check("v0.18.69: every arrival is checked and the 38 waiting providers are dropped once gone", function()
    assert(tailPending == 0, "providers still pending 3 minutes after the last arrival: " .. tostring(tailPending))
    local log = readFile(LOG)
    assert(log:find("travel sign discovery scan pass=1 components=0 providers=2394", 1, true), "first scan line missing")
end)

check("v0.18.69: background loop, nobody connected: a controller walk on heartbeat rounds only", function()
    for i = 2, 6 do
        local m = minutes[i]
        assert(m.bgPC <= 7, "minute " .. i .. ": " .. m.bgPC .. " controller walks (v0.18.68: 40)")
        assert(m.bgND == 0, "minute " .. i .. ": " .. m.bgND .. " net-driver walks")
    end
    for i = 1, 2 do assert(afterMinutes[i].bgPC <= 8, "after the player left, minute " .. i .. ": " .. afterMinutes[i].bgPC) end
end)

check("v0.18.69: background loop, one player in: a controller walk every round, no net-driver walk to find his connection", function()
    assert(possessed, "the player was never serviced (no JOINER POSSESSED line)")
    for i = 1, 2 do
        local m = playerMinutes[i]
        assert(m.bgPC >= 39, "minute " .. i .. ": " .. m.bgPC .. " controller walks (want every round)")
        assert(m.bgND == 0, "minute " .. i .. ": " .. m.bgND .. " net-driver walks (v0.18.68: one a round)")
    end
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
