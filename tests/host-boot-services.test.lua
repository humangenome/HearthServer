-- Run from the repository root: lua5.4 tests/host-boot-services.test.lua [path/to/bw_host/main.lua]
-- bw_host v0.18.62: the first minutes after a start.
-- The background service loop was busy for 70-130 s after "listen server UP" (10/24 lab boots, 10/17
-- canary): the first travel-sign scan queues 800-2,700 map-icon providers and one pass looked each up
-- by path. In that time a Stop's save request (force-save marker) was never read: "save-and-quit NOT
-- confirmed (killing anyway)" on every version's canary. Checks:
--   * the force-save marker is served by the game-thread pump alone, within 2 s, once, and removed;
--   * one background pass checks every sign provider and at most 40 others; the rest follow in later
--     passes until none are left.
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
local bgPathLookups = {}
local saves = {}
local cheatCandidates = {}
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
        if name == "MistCheatingComponent" then return cheatCandidates end
        return {}
    end,
    FindFirstOf = function(name)
        if name == "MistCheatingComponent" then
            return { IsValid = function() return true end, Save = function(_, slot, n) saves[#saves + 1] = tostring(slot) .. ":" .. tostring(n) end }
        end
        if name == "GameEngine" then return engine end
        if name == "World" then return world end
        return nil
    end,
    StaticFindObject = function(p)
        if onGameThread then gtPathLookups[p] = (gtPathLookups[p] or 0) + 1 else bgPathLookups[p] = (bgPathLookups[p] or 0) + 1 end
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


local SIGNS, OTHERS = 6, 300
for i = 1, SIGNS do
    local owner = register(classed(uobj(6000 + i * 10, "FastTravelSign_C " .. LEVEL .. "FastTravelSign_C_" .. i), { "FastTravelSign_C" }))
    local prov = register(classed(uobj(6002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "FastTravelSign_C_" .. i .. ".MapIcon", {}),
        { "MistMapIconProviderComponent", "ActorComponent" }))
    prov.GetOwner = function() return owner end
    providers[#providers + 1] = prov
end
for i = 1, OTHERS do
    local owner = register(classed(uobj(20000 + i * 10, "BP_Npc_C " .. LEVEL .. "BP_Npc_C_" .. i), { "BP_Npc_C" }))
    local prov = register(classed(uobj(20002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "BP_Npc_C_" .. i .. ".MapIcon", {}),
        { "MistMapIconProviderComponent", "ActorComponent" }))
    prov.GetOwner = function() return owner end
    providers[#providers + 1] = prov
end
local function lookupsOf(t, pat)
    local n = 0
    for p, v in pairs(t) do if p:find(pat, 1, true) then n = n + v end end
    return n
end

check("the force-save marker is served by the game-thread pump alone, within 2 s, once", function()
    local marker = dir .. "/Logs\\hearth_force_save_7777.marker"
    local f = assert(io.open(marker, "w")); f:write("1"); f:close()
    saves = {}
    NOW = NOW + 3
    runPump()
    assert(#saves == 1 and saves[1] == "4:TEMP", "saves after one pump frame: " .. #saves)
    assert(io.open(marker, "r") == nil, "the marker was not removed")
    NOW = NOW + 3
    runPump(); runPump()
    assert(#saves == 1, "saved again without a new request: " .. #saves)
    assert(readFile(LOG):find("force-save requested through MistCheatingComponent slot=Auto name=TEMP", 1, true), "save line missing")
end)

-- v0.18.63: which controller gets a Stop's save request
local function cheatOn(name, hasState, isLocal, pawn)
    local state = hasState and { IsValid = function() return true end } or nil
    local owner = {
        IsValid = function() return true end,
        GetFullName = function() return "OasisPlayerController_C /Game/Map.Map:PersistentLevel." .. name end,
        IsLocalController = function() return isLocal end,
        PlayerState = state,
        Pawn = pawn,
    }
    local component = {
        alive = true,
        GetOuter = function() return owner end,
        Save = function(_, slot, n) saves[#saves + 1] = name .. ":" .. tostring(slot) .. ":" .. tostring(n) end,
    }
    component.IsValid = function() return component.alive end
    return component
end
local function setCheats(list)
    for _, old in ipairs(cheatCandidates) do old.alive = false end
    cheatCandidates = list
end
local function requestSave()
    local marker = dir .. "/Logs\\hearth_force_save_7777.marker"
    local f = assert(io.open(marker, "w")); f:write("1"); f:close()
    saves = {}
    NOW = NOW + 3
    runPump()
end

check("a Stop's save goes to the host's controller, not a player who just left (no player state)", function()
    setCheats({ cheatOn("Left_C_3", false, false), cheatOn("Player_C_1", true, false), cheatOn("Host_C_0", true, true) })
    requestSave()
    assert(#saves == 1 and saves[1] == "Host_C_0:4:TEMP", "saved through: " .. tostring(saves[1]))
    assert(readFile(LOG):find("force-save picked Host_C_0 player_state=yes host=yes host_pawn_battle=no_pawn", 1, true), "pick line missing")
end)

check("the pick line says when the host's pawn is in a battle", function()
    local inBattle = { IsValid = function() return true end, GetBattleActor = function() return { IsValid = function() return true end } end }
    setCheats({ cheatOn("Host_C_0", true, true, inBattle) })
    requestSave()
    assert(readFile(LOG):find("force-save picked Host_C_0 player_state=yes host=yes host_pawn_battle=yes", 1, true), "battle line missing")
end)

check("with no host controller a player's controller with a player state is used", function()
    setCheats({ cheatOn("Left_C_3", false, false), cheatOn("Player_C_1", true, false) })
    requestSave()
    assert(#saves == 1 and saves[1] == "Player_C_1:4:TEMP", "saved through: " .. tostring(saves[1]))
    assert(readFile(LOG):find("force-save picked Player_C_1 player_state=yes host=no host_pawn_battle=unknown", 1, true), "pick line missing")
end)

check("with no player state anywhere the first live component is used, as before", function()
    setCheats({ cheatOn("Left_C_3", false, false) })
    requestSave()
    assert(#saves >= 1, "no save asked for")
    assert(readFile(LOG):find("player_state=no host=no host_pawn_battle=unknown", 1, true), "pick line missing")
    setCheats({})
end)

check("one background pass checks every sign provider and at most 40 others; the rest follow until none are left", function()
    local t = 10
    bgPathLookups = {}
    mod.serviceTravelSignDiscovery(t); t = t + 3          -- the scan pass queues every provider
    local queued = lookupsOf(bgPathLookups, "MapIcon")
    mod.serviceTravelSignDiscovery(t); t = t + 3          -- the first remember pass
    local first = lookupsOf(bgPathLookups, "MapIcon") - queued
    local signs = lookupsOf(bgPathLookups, "FastTravelSign_C_")
    assert(signs >= SIGNS, "sign providers not all checked in the first pass: " .. signs)
    assert(first <= SIGNS + 40, "first pass looked up " .. first .. " providers (v0.18.61: all " .. (SIGNS + OTHERS) .. ")")
    local passes = 1
    while lookupsOf(bgPathLookups, "BP_Npc_C_") < OTHERS and passes < 30 do
        mod.serviceTravelSignDiscovery(t); t = t + 3
        passes = passes + 1
    end
    assert(lookupsOf(bgPathLookups, "BP_Npc_C_") == OTHERS, "not every provider was checked: " .. lookupsOf(bgPathLookups, "BP_Npc_C_"))
    assert(passes <= 9, "took " .. passes .. " passes")
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
