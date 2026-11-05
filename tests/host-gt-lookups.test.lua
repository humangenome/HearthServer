-- Run from the repository root: lua5.4 tests/host-gt-lookups.test.lua [path/to/bw_host/main.lua]
-- bw_host v0.18.62: game-thread lookups by path, and the pump's timing line.
-- The 10/24 fog lab read 50-70 ms for one StaticFindObject of a joiner's object on the game
-- thread (inference from bw_fog's timing). The travel-sign repair runs on the game thread for
-- every known sign, three passes after each join, and looked up every remote pawn once per sign.
-- Checks:
--   * a player-sync batch over N signs with P remote players looks each pawn up once (P lookups,
--     v0.18.61 made N x P) and still repairs every sign for every player (N x P repair calls);
--   * the blueprint library is looked up once per batch;
--   * the pump logs one "gt" line a minute with the time per callback label and the lookups;
--   * a lookup from another Lua thread while a callback runs is not counted as game-thread time.
-- bw_host next version (2026-10-30): a batch of signs walks each class once instead of looking every component and provider
-- up by path; the real "gt" lines read 3.6-6.2 s frozen per pass, three passes per join.
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua"
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/Logs' '" .. dir .. "/HearthServer'"))
local SERVER_DIR = dir .. "/HearthServer"
local ROSTER = SERVER_DIR .. "\\roster.json" -- the mod joins with a backslash
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
local world = uobj(9500, "World " .. LEVEL:gsub(":PersistentLevel%.$", ""), { NetDriver = driver })
local viewport = uobj(9600, "GameViewportClient /Engine/Transient.GameEngine_0:GameViewportClient_0", { bDisableWorldRendering = false })
local engine = uobj(9700, "GameEngine /Engine/Transient.GameEngine_0", { GameViewport = viewport })
local session = uobj(8100, "MistOasisGameSession_C " .. LEVEL .. "MistOasisGameSession_C_0", { MaxPlayers = 5 })
local gm = uobj(8000, "BP_MistOasisGameMode_C " .. LEVEL .. "BP_MistOasisGameMode_C_0",
    { NumPlayers = 2, NumTravellingPlayers = 0, NumSpectators = 0, GameSession = session })
local pcs = {}

local onGameThread = false
local gtPathLookups = {}
local byPath = {}
local components, providers = {}, {}
local gameThreadWalks = {}
local function gameWalkCount()
    local n = 0
    for _, v in pairs(gameThreadWalks) do n = n + v end
    return n
end
local noop = function() return nil end
-- v0.18.61: game-thread callbacks run from the pump the mod registers with LoopInGameThreadAfterFrames
local gtPump = nil
local env = setmetatable({
    LoopInGameThreadAfterFrames = function(_, callback) gtPump = callback end,
    os = stubOs,
    LoopAsync = noop, ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = noop, RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback)
        local was = onGameThread
        onGameThread = true
        callback()
        onGameThread = was
    end,
    FindAllOf = function(name)
        if onGameThread then gameThreadWalks[name] = (gameThreadWalks[name] or 0) + 1 end
        if name == "IpNetDriver" then return { driver } end
        if name == "World" then return { world } end
        if name == "GameViewportClient" then return { viewport } end
        if name == "PlayerController" then return pcs end
        if name == "GameModeBase" then return { gm } end
        if name == "MistFastTravelComponent" then return components end
        if name == "MistMapIconProviderComponent" then return providers end
        return {}
    end,
    FindFirstOf = function(name)
        if name == "GameEngine" then return engine end
        if name == "World" then return world end
        return nil
    end,
    StaticFindObject = function(p)
        if onGameThread then gtPathLookups[p] = (gtPathLookups[p] or 0) + 1 end
        return byPath[p]
    end,
    print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })

local exports = "\nreturn { serviceJoiners = serviceJoiners, serviceTravelSignDiscovery = serviceTravelSignDiscovery,"
    .. " requestTravelSignPlayerSync = requestTravelSignPlayerSync }\n"
local mod = assert(load(source .. exports, "main.lua", "t", env))()
GAME_THREAD_WATCH_REF = env.GAME_THREAD_WATCH or rawget(env, "GAME_THREAD_WATCH")
local onGameThreadPump = nil
local function runPump()
    if not gtPump then return end
    if onGameThreadPump then onGameThreadPump(gtPump) else gtPump() end
end
for k, v in pairs(mod) do
    if type(v) == "function" then
        mod[k] = function(...)
            local r = table.pack(v(...))
            runPump()
            return table.unpack(r, 1, r.n)
        end
    end
end
-- this test counts searches made on the game thread: the pump is the game thread
onGameThreadPump = function(cb)
    local was = onGameThread
    onGameThread = true
    cb()
    onGameThread = was
end
runPump() -- the first frame: boot steps

local function controller(addr, serial, opts)
    opts = opts or {}
    local ps = uobj(addr + 1, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_" .. serial,
        { bOnlySpectator = false, PlayerNamePrivate = opts.name or "Player", GetPlayerName = function() return opts.name or "Player" end })
    return uobj(addr, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_" .. serial,
        { PlayerState = ps, Player = (opts.host or false) and LOCAL_PLAYER or nil, IsLocalPlayerController = function() return opts.host or false end })
end
local function readFile(p)
    local f = io.open(p, "r"); if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end

local passed, failed = 0, 0
local function check(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end


-- class chain helper: an object whose class (and its parents) carry these names
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
local function pathOf(o) return o.__name:match("^%S+%s+(%S.*)$") end
local function register(o) byPath[pathOf(o)] = o; return o end

local library = { IsValid = function() return true end, calls = 0 }
function library:SetMapIconDiscovered(cls, v) self.calls = self.calls + 1 end
byPath["/Script/Mist.Default__MistBlueprintLibrary"] = library
local iconClass = uobj(5000, "Class /Script/Mist.MistMapFastTravelIconComponent")
iconClass.GetFName = function() return { ToString = function() return "MistMapFastTravelIconComponent" end } end

local SIGNS = 6
for i = 1, SIGNS do
    local owner = register(classed(uobj(6000 + i * 10, "FastTravelSign_C " .. LEVEL .. "FastTravelSign_C_" .. i), { "FastTravelSign_C" }))
    local comp = register(classed(uobj(6001 + i * 10, "MistFastTravelComponent " .. LEVEL .. "FastTravelSign_C_" .. i .. ".FastTravel", { RemainingUses = 1 }),
        { "MistFastTravelComponent", "ActorComponent" }))
    comp.GetOwner = function() return owner end
    comp.HandleRoadGraphUpdate = function() end
    local prov = register(classed(uobj(6002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "FastTravelSign_C_" .. i .. ".MapIcon", { MapIconClass = iconClass }),
        { "MistMapIconProviderComponent", "ActorComponent" }))
    prov.GetOwner = function() return owner end
    components[i], providers[i] = comp, prov
end

local repairs = 0
local function remote(addr, serial, name)
    local pc = controller(addr, serial, { name = name })
    pc.Pawn = register(classed(uobj(addr + 100, "Player_C " .. LEVEL .. "Player_C_" .. serial), { "Player_C", "MistPlayer", "Character", "Pawn" }))
    pc.Pawn.ServerRepairTravelComponent = function() repairs = repairs + 1 end
    return pc
end
local hostPc = controller(1100, 20, { host = true })
local hal, bea = remote(1200, 21, "Hal"), remote(1400, 22, "Bea")
pcs[1], pcs[2], pcs[3] = hostPc, hal, bea
local idf = assert(io.open(SERVER_DIR .. "\\login-identities.tsv", "w"))
idf:write(table.concat({ tostring(NOW * 1000), "", "steam_76561198000000051", "steam_76561198000000051", "Hal", "", "" }, "\t"), "\n")
idf:write(table.concat({ tostring(NOW * 1000), "", "steam_76561198000000052", "steam_76561198000000052", "Bea", "", "" }, "\t"), "\n")
idf:close()
conns[1] = uobj(9200, "IpConnection /Engine/Transient.IpConnection_21", { OwningActor = hal })
conns[2] = uobj(9201, "IpConnection /Engine/Transient.IpConnection_22", { OwningActor = bea })

local function pawnLookups()
    local n = 0
    for p, v in pairs(gtPathLookups) do if p:find("Player_C_", 1, true) then n = n + v end end
    return n
end

-- the join service fills the remote player list; the travel-sign service discovers the signs
local t = 10
for _ = 1, 6 do mod.serviceJoiners(t); t = t + 3 end
for _ = 1, 4 do mod.serviceTravelSignDiscovery(t); runPump(); t = t + 3 end

check("discovery repaired the signs it found", function()
    local log = readFile(LOG)
    local n = 0
    for _ in log:gmatch("travel sign discovery repaired owner=") do n = n + 1 end
    assert(n >= SIGNS, "repaired lines: " .. n .. "\n" .. log:sub(-2000))
end)

check("a player-sync pass over " .. SIGNS .. " signs looks each of the 2 remote pawns up once and repairs every sign for both", function()
    gtPathLookups = {}
    repairs = 0
    library.calls = 0
    mod.requestTravelSignPlayerSync("test")
    -- one pass: queue (service) then the game-thread batch (pump)
    mod.serviceTravelSignDiscovery(t); runPump(); t = t + 3
    assert(repairs == SIGNS * 2, "player repairs " .. repairs .. ", want " .. SIGNS * 2)
    assert(pawnLookups() == 2, "pawn lookups by path in one batch: " .. pawnLookups() .. " (v0.18.61: " .. SIGNS * 2 .. ")")
    assert((gtPathLookups["/Script/Mist.Default__MistBlueprintLibrary"] or 0) == 1,
        "blueprint library lookups: " .. tostring(gtPathLookups["/Script/Mist.Default__MistBlueprintLibrary"]))
end)

check("the pump logs one gt line a minute with the time per callback and the lookups", function()
    NOW = NOW + 61
    mod.requestTravelSignPlayerSync("test-2")
    mod.serviceTravelSignDiscovery(t); runPump(); t = t + 3
    local log = readFile(LOG)
    local line = log:match("gt %d+s: [^\r\n]*")
    assert(line, "no gt line in the log")
    assert(line:find("travel%-sign%-discovery n=%d+ ms=") and line:find("lookups path=%d+"), "gt line: " .. line)
end)

check("a lookup from another Lua thread while a callback runs is not counted", function()
    local W = GAME_THREAD_WATCH_REF
    local before = (W.lk and W.lk.path) or 0
    W.inPump = true
    local co = coroutine.create(function() end)
    local saved = W.gtCo
    W.gtCo = co                    -- the game thread is some other Lua thread
    W.lookup("path", 5)            -- called from this (background) thread
    W.inPump = false
    W.gtCo = saved
    assert(((W.lk and W.lk.path) or 0) == before, "background lookup was counted")
end)

check("a batch of signs walks each class once and looks no sign up by path", function()
    gtPathLookups, gameThreadWalks = {}, {}
    repairs = 0
    mod.requestTravelSignPlayerSync("walk")
    mod.serviceTravelSignDiscovery(t); runPump(); t = t + 3
    assert(repairs == SIGNS * 2, "player repairs " .. repairs .. ", want " .. SIGNS * 2)
    for p in pairs(gtPathLookups) do
        assert(not p:find("FastTravelSign_C_", 1, true), "a sign object was looked up by path: " .. p)
    end
    assert(gameThreadWalks["MistFastTravelComponent"] == 1, "component walks: " .. tostring(gameThreadWalks["MistFastTravelComponent"]))
    assert(gameThreadWalks["MistMapIconProviderComponent"] == 1, "provider walks: " .. tostring(gameThreadWalks["MistMapIconProviderComponent"]))
end)

check("a sign the walk does not list falls back to the lookup by path and is still repaired", function()
    gtPathLookups, gameThreadWalks = {}, {}
    repairs = 0
    local hidden = table.remove(components)
    mod.requestTravelSignPlayerSync("walk-miss")
    mod.serviceTravelSignDiscovery(t); runPump(); t = t + 3
    components[#components + 1] = hidden
    local bySign = 0
    for p, v in pairs(gtPathLookups) do
        if p:find("FastTravelSign_C_", 1, true) then bySign = bySign + v end
    end
    assert(bySign == 1, "lookups by path for signs: " .. bySign)
    assert(repairs == SIGNS * 2, "player repairs " .. repairs .. ", want " .. SIGNS * 2)
end)

check("a batch under walkMin signs keeps the lookup by path", function()
    -- ObjRef sits inside a do-block, so this one reads the source: the two-sign path has no mocked way in
    assert(source:find("if (batch.size or 0) < ObjRef.walkMin then return ObjRef.resolve(key, className) end", 1, true), "small-batch path is gone")
    assert(source:find("local looked = { size = #batch }", 1, true), "the batch no longer carries its size")
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
