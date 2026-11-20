-- Run from the repository root: lua5.4 tests/host-boot-services.test.lua [path/to/bw_host/main.lua]
-- bw_host v0.18.62: the first minutes after a start.
-- The background service loop was busy for 70-130 s after "listen server UP" (10/24 lab boots, 10/17
-- canary): the first travel-sign scan queues 800-2,700 map-icon providers and one pass looked each up
-- by path. In that time a Stop's save request (force-save marker) was never read: "save-and-quit NOT
-- confirmed (killing anyway)" on every version's canary. Checks:
--   * the force-save marker is served by the game-thread pump alone, within 2 s, once, and removed;
--   * v0.18.66: the Travel Sign service touches no game object off the game thread. The startup scan
--     checks every provider it walks with the object in hand (no lookup by path); a provider with no
--     owner yet waits and is checked on later passes; providers the construction hook queues are checked
--     on the game thread, every sign provider and at most 40 others per pass, until none are left; a
--     Blueprint component template (_GEN_VARIABLE) is never queued.
--   * v0.18.67: a name the pass's walk does not list is dropped with no lookup by path; Default__ names never queued.
--   * v0.18.68: "no owner yet" rechecked every 30 s; 1-2 due names wait up to 15 s then one walk; a pass starts no
--     second piece after 40 ms (a slow-walk mock proves it).
--   * v0.18.69: a scan pass's component walk comes a minute after its provider walk; while the startup scan runs,
--     waiting and new provider names are checked by that provider walk; after it, at most one provider walk per 30 s.
--     (tests/host-start-minutes.test.lua measures the first minutes as a whole.)
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
local bgWalks = {}
local hooks = {}
local slowWalkMs = 0 -- v0.18.68 budget check: a walk that takes this long (a real one is about 60 ms)
ownerAsks = 0       -- v0.18.68 recheck check: GetOwner calls on the waiting providers
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
    NotifyOnNewObject = function(path, callback) hooks[path] = callback end,
    RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback)
        local was = onGameThread
        onGameThread = true
        callback()
        onGameThread = was
    end,
    FindAllOf = function(name)
        if onGameThread then gameThreadWalks[name] = (gameThreadWalks[name] or 0) + 1
        else bgWalks[name] = (bgWalks[name] or 0) + 1 end
        if slowWalkMs > 0 then local t0 = os.clock(); while (os.clock() - t0) * 1000 < slowWalkMs do end end
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

local function sg() return rawget(env, "BG_LOOP").sg end
local function walksOff(name) return bgWalks[name] or 0 end

check("v0.18.66: the startup scan checks every walked provider on the game thread with the object in hand", function()
    local t = 10
    bgPathLookups, gtPathLookups, bgWalks = {}, {}, {}
    local before = sg() and sg().checked or 0
    mod.serviceTravelSignDiscovery(t); t = t + 3          -- background: a scan pass is due; the pump runs it
    assert(lookupsOf(bgPathLookups, "MapIcon") == 0 and lookupsOf(gtPathLookups, "MapIcon") == 0,
        "provider lookups by path: background " .. lookupsOf(bgPathLookups, "MapIcon") .. ", game thread " .. lookupsOf(gtPathLookups, "MapIcon"))
    assert(walksOff("MistMapIconProviderComponent") == 0 and walksOff("MistFastTravelComponent") == 0, "a walk ran off the game thread")
    assert(sg().checked - before >= SIGNS + OTHERS, "providers checked in the scan pass: " .. (sg().checked - before))
    mod.serviceTravelSignDiscovery(t); t = t + 3
    assert(sg().pending == 0, "providers still queued after the scan pass: " .. sg().pending)
    -- v0.18.69: the pass's component walk (and its line) comes a minute after its provider walk
    assert(not readFile(LOG):find("travel sign discovery scan pass=1 ", 1, true), "component walk on the next pass")
    local t0 = t
    repeat mod.serviceTravelSignDiscovery(t); t = t + 3
    until readFile(LOG):find("travel sign discovery scan pass=1 components=%d+ providers=%d+") or t - t0 > 70
    assert(readFile(LOG):find("travel sign discovery scan pass=1 components=%d+ providers=%d+"), "scan line missing")
    assert(t - t0 >= 50, "component walk " .. (t - t0) .. " s after the provider walk")
end)

check("v0.18.66: a provider with no owner yet waits, and a later pass checks it on the game thread", function()
    local t = 400
    local owner = register(classed(uobj(90000, "BP_Late_C " .. LEVEL .. "BP_Late_C_1"), { "BP_Late_C" }))
    local late = register(classed(uobj(90002, "MistMapIconProviderComponent " .. LEVEL .. "BP_Late_C_1.MapIcon", {}),
        { "MistMapIconProviderComponent", "ActorComponent" }))
    late.GetOwner = function() return nil end
    providers[#providers + 1] = late
    hooks["/Script/Mist.MistMapIconProviderComponent"](late)
    bgPathLookups, gtPathLookups = {}, {}
    mod.serviceTravelSignDiscovery(t); t = t + 3
    mod.serviceTravelSignDiscovery(t); t = t + 3
    assert(sg().pending == 1, "the ownerless provider is not waiting: pending=" .. sg().pending)
    late.GetOwner = function() return owner end
    -- v0.18.68: rechecked 30 s (loop clock) after its "no owner yet", through a walk
    -- v0.18.69: while the startup scan runs, by the scan's own provider walk (a pass every 2 minutes)
    local t0 = t
    repeat mod.serviceTravelSignDiscovery(t); t = t + 3 until sg().pending == 0 or t - t0 > 130
    assert(sg().pending == 0, "the provider was not taken once its owner resolved: pending=" .. sg().pending)
    assert(lookupsOf(bgPathLookups, "BP_Late_C_1") == 0, "looked up off the game thread")
    assert(lookupsOf(gtPathLookups, "BP_Late_C_1") == 0, "looked up by path (v0.18.68 checks through a walk)")
end)

check("v0.18.66: hook arrivals: every sign provider and at most 40 others per game-thread pass, until none are left", function()
    local t = 600
    -- past the startup window (8 scan passes, 60 s apart): from here only the hooks queue providers
    -- v0.18.68: each scan pass is two pieces (providers, then components), so run until the window is over
    local calls = 0
    repeat mod.serviceTravelSignDiscovery(t); t = t + 31; calls = calls + 1
    until readFile(LOG):find("travel sign discovery startup scan complete passes=8", 1, true) or calls > 60
    assert(readFile(LOG):find("travel sign discovery startup scan complete passes=8", 1, true), "startup window not over")
    local ARRIVALS, SIGN_ARRIVALS = 100, 2
    for i = 1, ARRIVALS do
        local owner = register(classed(uobj(100000 + i * 10, "BP_Wolf_C " .. LEVEL .. "BP_Wolf_C_" .. i), { "BP_Wolf_C" }))
        local prov = register(classed(uobj(100002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "BP_Wolf_C_" .. i .. ".MapIcon", {}),
            { "MistMapIconProviderComponent", "ActorComponent" }))
        prov.GetOwner = function() return owner end
        providers[#providers + 1] = prov
        hooks["/Script/Mist.MistMapIconProviderComponent"](prov)
    end
    for i = 1, SIGN_ARRIVALS do
        local owner = register(classed(uobj(200000 + i * 10, "FastTravelSign_C " .. LEVEL .. "FastTravelSign_C_9" .. i), { "FastTravelSign_C" }))
        local prov = register(classed(uobj(200002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "FastTravelSign_C_9" .. i .. ".MapIcon", {}),
            { "MistMapIconProviderComponent", "ActorComponent" }))
        prov.GetOwner = function() return owner end
        providers[#providers + 1] = prov
        hooks["/Script/Mist.MistMapIconProviderComponent"](prov)
    end
    -- a Blueprint's component template is never queued (its owner never resolves)
    local template = classed(uobj(300002, "MistMapIconProviderComponent /Game/Mist/Npc/BP_Wolf.BP_Wolf_C:MapIcon_GEN_VARIABLE", {}),
        { "MistMapIconProviderComponent", "ActorComponent" })
    hooks["/Script/Mist.MistMapIconProviderComponent"](template)
    bgPathLookups, bgWalks, gameThreadWalks = {}, {}, {}
    local passes, worst = 0, 0
    repeat
        local before = sg().checked
        mod.serviceTravelSignDiscovery(t); t = t + 3
        passes = passes + 1
        local checked = sg().checked - before
        if checked > worst then worst = checked end
        if passes == 1 then
            assert(sg().pending == ARRIVALS + SIGN_ARRIVALS, "queued arrivals: " .. sg().pending .. " (the template must not be queued)")
        end
    until sg().pending == 0 or passes > 40
    assert(sg().pending == 0, "arrivals left after " .. passes .. " passes: " .. sg().pending)
    assert(worst <= SIGN_ARRIVALS + 40, "one pass checked " .. worst .. " providers")
    -- v0.18.69: one provider walk per 30 s: 102 names in 3 walks (42, 40, 20), about a minute
    assert((gameThreadWalks["MistMapIconProviderComponent"] or 0) == 3, "provider walks: " .. tostring(gameThreadWalks["MistMapIconProviderComponent"]))
    assert(passes >= 20 and passes <= 22, "passes: " .. passes)
    assert(lookupsOf(bgPathLookups, "MapIcon") == 0 and walksOff("MistMapIconProviderComponent") == 0, "provider work off the game thread")
end)

-- v0.18.67, from the 2026-11-14 lab: in the minute a player joined, one pass held the game thread 3.6 s with 61 lookups by
-- path. The construction hook takes a provider's name while it is being spawned; by the pass it has another name (or is
-- gone), the walk does not list the hook's name, and v0.18.66 then looked it up by path, about 60 ms each.
check("v0.18.67: names the walk does not list are dropped with no lookup by path; Default__ names are never queued", function()
    local t = 2000
    local ARRIVALS = 61
    for i = 1, ARRIVALS do
        local owner = register(classed(uobj(400000 + i * 10, "Player_C " .. LEVEL .. "Player_C_7" .. i), { "Player_C" }))
        local prov = classed(uobj(400002 + i * 10, "MistMapIconProviderComponent /Engine/Transient.MistMapIconProviderComponent_" .. i, {}),
            { "MistMapIconProviderComponent", "ActorComponent" })
        prov.GetOwner = function() return owner end
        hooks["/Script/Mist.MistMapIconProviderComponent"](prov)        -- the hook sees the spawn-time name
        prov.__name = "MistMapIconProviderComponent " .. LEVEL .. "Player_C_7" .. i .. ".MapIcon"   -- renamed afterwards
        providers[#providers + 1] = prov
    end
    for i = 1, 2 do
        local cdoSub = classed(uobj(500000 + i, "MistMapIconProviderComponent /Game/Mist/Npc/BP_Wolf.Default__BP_Wolf_C:MapIcon" .. i, {}),
            { "MistMapIconProviderComponent", "ActorComponent" })
        hooks["/Script/Mist.MistMapIconProviderComponent"](cdoSub)
        local cdoComp = classed(uobj(510000 + i, "MistFastTravelComponent /Game/Mist/Signs/BP_Sign.Default__FastTravelSign_C:FastTravel" .. i, {}),
            { "MistFastTravelComponent", "ActorComponent" })
        hooks["/Script/Mist.MistFastTravelComponent"](cdoComp)
    end
    gtPathLookups, bgPathLookups = {}, {}
    local beforeGone = sg().gone or 0
    local passes = 0
    repeat
        mod.serviceTravelSignDiscovery(t); t = t + 3
        passes = passes + 1
        if passes == 1 then
            assert(sg().pending == ARRIVALS, "queued: " .. sg().pending .. " (Default__ names must not be queued)")
        end
    until sg().pending == 0 or passes > 20   -- v0.18.69: 61 names, 2 walks 30 s apart
    assert(sg().pending == 0, "left after " .. passes .. " passes: " .. sg().pending)
    assert(lookupsOf(gtPathLookups, "Transient") == 0 and lookupsOf(bgPathLookups, "Transient") == 0,
        "lookups by path of names the walk did not list: " .. lookupsOf(gtPathLookups, "Transient"))
    assert(lookupsOf(gtPathLookups, "Default__BP_Wolf_C") == 0 and lookupsOf(gtPathLookups, "Default__FastTravelSign_C") == 0,
        "a Default__ name from the hook was looked up")
    assert((sg().gone or 0) - beforeGone >= ARRIVALS, "names counted as gone: " .. ((sg().gone or 0) - beforeGone))
end)

-- v0.18.68, from the 2026-11-14 re-lab of v0.18.67: 1.5-1.6 s a minute of game-thread time in the first minutes (a walk
-- every 3 s to recheck providers with no owner yet) and a 257 ms pass in the join minute (several walks and lookups by path
-- in one callback).
check("v0.18.68: providers with no owner yet are rechecked every 30 s, not on every pass", function()
    local t = 3000
    for i = 1, 5 do
        local prov = register(classed(uobj(600002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "BP_Deer_C_" .. i .. ".MapIcon", {}),
            { "MistMapIconProviderComponent", "ActorComponent" }))
        prov.GetOwner = function() ownerAsks = ownerAsks + 1; return nil end
        providers[#providers + 1] = prov
        hooks["/Script/Mist.MistMapIconProviderComponent"](prov)
    end
    gameThreadWalks, gtPathLookups = {}, {}
    ownerAsks = 0
    for _ = 1, 12 do mod.serviceTravelSignDiscovery(t); t = t + 3 end   -- 36 s of the loop clock
    assert(ownerAsks == 10, "owner checks of the 5 waiting providers in 36 s: " .. ownerAsks .. " (want 2 each; v0.18.67: 12 each)")
    assert(lookupsOf(gtPathLookups, "BP_Deer_C_") == 0, "looked up by path")
    assert(sg().pending == 5, "still waiting: " .. sg().pending)
    for i = #providers, 1, -1 do if providers[i].__name:find("BP_Deer_C_", 1, true) then table.remove(providers, i) end end
    for _ = 1, 12 do mod.serviceTravelSignDiscovery(t); t = t + 3 end   -- gone from the world: dropped at the next recheck
    assert(sg().pending == 0, "gone providers still queued: " .. sg().pending)
end)

check("v0.18.68: one or two due names wait up to 15 s for company, then one walk checks them (no lookup by path)", function()
    local t = 4000
    mod.serviceTravelSignDiscovery(t); t = t + 3                        -- the hooks stamp new names with this clock
    local owner = register(classed(uobj(700000, "BP_Hare_C " .. LEVEL .. "BP_Hare_C_1"), { "BP_Hare_C" }))
    local prov = register(classed(uobj(700002, "MistMapIconProviderComponent " .. LEVEL .. "BP_Hare_C_1.MapIcon", {}),
        { "MistMapIconProviderComponent", "ActorComponent" }))
    prov.GetOwner = function() return owner end
    providers[#providers + 1] = prov
    hooks["/Script/Mist.MistMapIconProviderComponent"](prov)
    gameThreadWalks, gtPathLookups = {}, {}
    local firstWalkAt = nil
    for _ = 1, 8 do
        mod.serviceTravelSignDiscovery(t)
        if not firstWalkAt and (gameThreadWalks["MistMapIconProviderComponent"] or 0) > 0 then firstWalkAt = t end
        t = t + 3
    end
    assert(firstWalkAt and firstWalkAt - 4000 >= 15, "a lone name was checked after " .. tostring(firstWalkAt and firstWalkAt - 4000) .. " s")
    assert((gameThreadWalks["MistMapIconProviderComponent"] or 0) == 1, "walks: " .. tostring(gameThreadWalks["MistMapIconProviderComponent"]))
    assert(lookupsOf(gtPathLookups, "BP_Hare_C_1") == 0, "looked up by path")
    assert(sg().pending == 0, "not taken: " .. sg().pending)
end)

check("v0.18.68: after its first piece a pass starts nothing more once it has used 40 ms; the rest runs next pass", function()
    local t = 5000
    for i = 1, 4 do
        local owner = register(classed(uobj(800000 + i * 10, "BP_Boar_C " .. LEVEL .. "BP_Boar_C_" .. i), { "BP_Boar_C" }))
        local prov = register(classed(uobj(800002 + i * 10, "MistMapIconProviderComponent " .. LEVEL .. "BP_Boar_C_" .. i .. ".MapIcon", {}),
            { "MistMapIconProviderComponent", "ActorComponent" }))
        prov.GetOwner = function() return owner end
        providers[#providers + 1] = prov
        hooks["/Script/Mist.MistMapIconProviderComponent"](prov)
    end
    mod.requestTravelSignPlayerSync("budget-test")                      -- a sweep and 4 due providers in one pass
    slowWalkMs = 45
    gameThreadWalks = {}
    local deferredBefore = sg().deferred or 0
    mod.serviceTravelSignDiscovery(t); t = t + 3
    local first = { comp = gameThreadWalks["MistFastTravelComponent"] or 0, prov = gameThreadWalks["MistMapIconProviderComponent"] or 0 }
    gameThreadWalks = {}
    mod.serviceTravelSignDiscovery(t); t = t + 3
    slowWalkMs = 0
    assert(first.comp + first.prov == 1, "walks in the first pass: components " .. first.comp .. ", providers " .. first.prov)
    assert((sg().deferred or 0) > deferredBefore, "nothing was left for the next pass")
    assert((gameThreadWalks["MistMapIconProviderComponent"] or 0) >= 1 or sg().pending == 0, "the deferred provider checks never ran")
    for _ = 1, 4 do mod.serviceTravelSignDiscovery(t); t = t + 3 end
    assert(sg().pending == 0, "providers left: " .. sg().pending)
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
