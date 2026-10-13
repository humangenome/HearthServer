-- Run from the repository root: lua5.4 tests/host-seat-count.test.lua
-- Optional first argument selects an older host mod for regression replay.
-- Loads the whole host mod against a stub UE4SS and checks two things the
-- heartbeat and the join service do with controllers:
--   * the seat count: the engine's NumPlayers + NumTravellingPlayers against the
--     live, non-spectating controllers, and the correction when it stays high;
--   * the dropped-connection rule: a player who was in the world and lost their
--     connection is left to the game, a controller that never had a player is
--     quarantined, and a controller that reuses a departed one's address starts
--     clean.
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua"
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/Logs'"))
local SERVER_DIR = dir .. "/HearthServer"
local TSV = SERVER_DIR .. "\\login-identities.tsv" -- the mod joins with a backslash
local LOG = dir .. "/Logs/bw_host.log"

local NOW = 1791600000
local ENV = { HEARTH_HOST_LOG = LOG, HEARTH_SERVER_DIR = SERVER_DIR }
local stubOs = setmetatable({
    time = function(t) if t then return os.time(t) end return NOW end,
    getenv = function(k) return ENV[k] end,
}, { __index = os })

local drivers, pcs, gameModes = {}, {}, {}
local noop = function() return nil end
local env = setmetatable({
    os = stubOs,
    LoopAsync = noop, ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = noop, RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback) callback() end,
    FindAllOf = function(name)
        if name == "IpNetDriver" then return drivers end
        if name == "PlayerController" then return pcs end
        if name == "GameModeBase" then return gameModes end
        return {}
    end,
    FindFirstOf = noop, StaticFindObject = noop, print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    -- UE4SS's API is capitalised; a lowercase miss is a helper used above its definition
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })

local exports = "\nreturn { seatCheck = ADMIN_AUTH.seatCheck, seat = ADMIN_AUTH.seat,"
    .. " service = shouldServiceRemoteController, quarantined = remoteQuarantinedByPc,"
    .. " live = ADMIN_AUTH.livePlayerByPc, serviceJoiners = serviceJoiners }\n"
local mod = assert(load(source .. exports, "main.lua", "t", env))()

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
local TRANSIT = "/Game/Mist/Maps/Dev/TransitionMap.TransitionMap:PersistentLevel."
local conns = { GetArrayNum = function(self) return #self end }
drivers[1] = uobj(9000, "IpNetDriver /Engine/Transient.IpNetDriver_0", { ClientConnections = conns })
local session = uobj(8100, "MistOasisGameSession_C " .. LEVEL .. "MistOasisGameSession_C_0", { MaxPlayers = 5 })
local gm = uobj(8000, "BP_MistOasisGameMode_C " .. LEVEL .. "BP_MistOasisGameMode_C_0",
    { NumPlayers = 0, NumTravellingPlayers = 0, NumSpectators = 0, GameSession = session })
gameModes[1] = gm

local function controller(addr, serial, opts)
    opts = opts or {}
    local ps = uobj(addr + 1, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_" .. serial,
        { bOnlySpectator = opts.spectator or false, GetPlayerName = function() return opts.name or "Player" end })
    local pc = uobj(addr, "OasisPlayerController_C " .. (opts.level or LEVEL) .. "OasisPlayerController_C_" .. serial,
        { PlayerState = ps, IsLocalPlayerController = function() return opts.host or false end })
    return pc
end
local function setControllers(list)
    for i = #pcs, 1, -1 do pcs[i] = nil end
    for i, pc in ipairs(list) do pcs[i] = pc end
end
local function logText()
    local f = io.open(LOG, "r"); if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end
local function countOf(text, needle)
    local n, i = 0, 1
    while true do
        local a, b = text:find(needle, i, true)
        if not a then return n end
        n, i = n + 1, b + 1
    end
end

local passed, failed = 0, 0
local function check(name, body, needsSeat)
    for i = #conns, 1, -1 do conns[i] = nil end
    if needsSeat and not mod.seatCheck then print("skip - " .. name .. " (no seat check in this mod)"); return end
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end

local host = controller(100, 0, { host = true })
local a = controller(200, 1)
local b = controller(300, 2)

check("a count that matches the live controllers is reported and left alone", function()
    setControllers({ host, a, b })
    gm.NumPlayers, gm.NumTravellingPlayers = 3, 0
    local info = mod.seatCheck(pcs)
    assert(info == " seats=3/3", "info was '" .. info .. "'")
    assert(mod.seatCheck(pcs) == " seats=3/3")
    assert(gm.NumPlayers == 3)
end, true)

check("a count stuck above the live controllers is corrected on the second heartbeat", function()
    setControllers({ host, a })        -- b's controller is gone, its seat never came back
    gm.NumPlayers, gm.NumTravellingPlayers = 4, 0
    local first = mod.seatCheck(pcs)
    assert(first:find("seats=4/2", 1, true) and first:find("watching", 1, true), first)
    assert(gm.NumPlayers == 4, "corrected on the first look")
    local second = mod.seatCheck(pcs)
    assert(second:find("correcting", 1, true), second)
    assert(gm.NumPlayers == 2, "NumPlayers is " .. tostring(gm.NumPlayers))
    assert(logText():find("seat count corrected NumPlayers 4 -> 2", 1, true), "no correction line")
    assert(logText():find("MaxPlayers=5", 1, true), "correction line misses MaxPlayers")
    assert(mod.seatCheck(pcs) == " seats=2/2")
end, true)

check("a join or leave between two heartbeats restarts the wait instead of correcting", function()
    setControllers({ host, a })
    gm.NumPlayers = 3
    assert(mod.seatCheck(pcs):find("watching", 1, true))
    setControllers({ host, a, controller(400, 3) }) -- someone joined; the count is right again
    gm.NumPlayers = 3
    assert(mod.seatCheck(pcs) == " seats=3/3")
    setControllers({ host, a })
    gm.NumPlayers = 3
    assert(mod.seatCheck(pcs):find("watching", 1, true), "a fresh excess must be watched first")
    assert(gm.NumPlayers == 3)
    assert(mod.seatCheck(pcs):find("correcting", 1, true))
    assert(gm.NumPlayers == 2)
end, true)

check("nothing is corrected while a player is travelling or the TransitionMap is up", function()
    setControllers({ host, a })
    gm.NumPlayers, gm.NumTravellingPlayers = 2, 1
    mod.seatCheck(pcs); mod.seatCheck(pcs); mod.seatCheck(pcs)
    assert(gm.NumPlayers == 2 and gm.NumTravellingPlayers == 1)
    gm.NumTravellingPlayers = 0
    setControllers({ host, controller(500, 4, { level = TRANSIT }) })
    gm.NumPlayers = 3
    mod.seatCheck(pcs); mod.seatCheck(pcs); mod.seatCheck(pcs)
    assert(gm.NumPlayers == 3, "corrected during a travel")
end, true)

check("spectators do not count as live players, and the count is never raised", function()
    local spec = controller(600, 5, { spectator = true })
    setControllers({ host, a, spec })
    gm.NumPlayers, gm.NumSpectators = 2, 1
    assert(mod.seatCheck(pcs) == " seats=2/2")
    gm.NumPlayers = 1                  -- under the live count: report only
    assert(mod.seatCheck(pcs) == " seats=1/2")
    assert(mod.seatCheck(pcs) == " seats=1/2")
    assert(gm.NumPlayers == 1)
end, true)

check("HEARTH_SEAT_HEAL=0 reports without correcting", function()
    mod.seat.enabled = false
    setControllers({ host })
    gm.NumPlayers = 3
    mod.seatCheck(pcs); mod.seatCheck(pcs); mod.seatCheck(pcs)
    assert(gm.NumPlayers == 3)
    assert(mod.seatCheck(pcs) == " seats=3/1")
    mod.seat.enabled = true
    gm.NumPlayers = 1
end, true)

check("a game mode without readable counts turns the check off with one line", function()
    local saved = gameModes[1]
    gameModes[1] = uobj(8001, "GameModeBase " .. LEVEL .. "GameModeBase_0", {})
    setControllers({ host })
    assert(mod.seatCheck(pcs) == "")
    assert(mod.seatCheck(pcs) == "")
    assert(countOf(logText(), "seat count: GameMode NumPlayers/NumTravellingPlayers not readable") == 1)
    gameModes[1] = saved
end, true)

-- Login rows the identity service reads (ts ms, address, uid, seed, display, name, ticket).
local function rows(list)
    local f = assert(io.open(TSV, "w"))
    for _, r in ipairs(list) do
        f:write(table.concat({ tostring(r.ts * 1000), "", "steam_" .. r.id, "steam_" .. r.id, r.display, "", "" }, "\t"), "\n")
    end
    f:close()
end
local function connect(pc, connAddr, serial)
    local conn = uobj(connAddr, "IpConnection /Engine/Transient.IpConnection_" .. serial, { OwningActor = pc })
    conns[#conns + 1] = conn
    return conn
end
local function drop(conn)
    for i = #conns, 1, -1 do if conns[i] == conn then table.remove(conns, i) end end
end

check("a player who was in the world and drops is left to the game, never quarantined", function()
    os.execute("mkdir -p '" .. SERVER_DIR .. "'")
    rows({ { ts = NOW, id = "76561198000000031", display = "Fay" } })
    local fay = controller(700, 6, { name = "Fay" })
    local conn = connect(fay, 7700, 6)
    assert(mod.service(fay, 10) == true, "Fay was not serviced while connected")
    if mod.live then assert(mod.live[700], "Fay not marked as a live player") end
    drop(conn)
    for t = 11, 200, 3 do assert(mod.service(fay, t) == false) end
    assert(not mod.quarantined[700], "a live player's dropped controller was quarantined")
    assert(countOf(logText(), "remote player connection dropped, controller left to the game") == 1)
end)

check("a controller that never had a live connection is quarantined after the wait", function()
    local ghost = controller(800, 7)
    assert(mod.service(ghost, 300) == false)
    assert(not mod.quarantined[800])
    assert(mod.service(ghost, 309) == false)
    assert(mod.quarantined[800], "the never-live controller was not quarantined")
end)

check("a new controller at a quarantined controller's address is serviced, not blocked", function()
    NOW = NOW + 30 -- the identity service re-reads HearthServer's file on a timer
    rows({ { ts = NOW, id = "76561198000000041", display = "Gil" } })
    local gil = controller(800, 9, { name = "Gil" }) -- same address as the quarantined ghost
    connect(gil, 8800, 9)
    assert(mod.service(gil, 400) == true, "the new player at a reused address was blocked")
    assert(not mod.quarantined[800])
end)

check("controllers on the TransitionMap are neither quarantined nor serviced", function()
    local hal = controller(900, 10, { level = TRANSIT })
    for t = 500, 600, 3 do assert(mod.service(hal, t) == false) end
    assert(not mod.quarantined[900], "quarantined on the TransitionMap")
end)

check("a full join-service pass runs with the host and a remote player on the server", function()
    for i = #conns, 1, -1 do conns[i] = nil end
    NOW = NOW + 30
    rows({ { ts = NOW, id = "76561198000000051", display = "Hal" } })
    local hostPc = controller(1100, 20, { host = true })
    local hal = controller(1200, 21, { name = "Hal" })
    connect(hal, 9200, 21)
    setControllers({ hostPc, hal })
    gm.NumPlayers, gm.NumTravellingPlayers = 2, 0
    for t = 700, 760, 3 do mod.serviceJoiners(t) end
    assert(not logText():find("serviceJoiners ERROR", 1, true), "the join service raised")
    assert(mod.live[1200], "Hal was not serviced by the full pass")
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
