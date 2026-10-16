-- Run from the repository root: lua5.4 tests/host-scan-budget.test.lua [path/to/bw_host/main.lua]
-- Loads the whole host mod against a stub UE4SS and counts full object searches (FindAllOf)
-- made on the GAME THREAD (inside ExecuteInGameThread callbacks). Each one walks the whole
-- object list and froze the server for 65-110 ms; the host runs a fixed 30 fps step, so a
-- frozen frame is world time lost. v0.18.58 walked every IpNetDriver on the game thread for
-- each roster write (every service pass with a player on) and every GameViewportClient on
-- each viewport re-assert (every 15 s). Checks:
--   * with the listen world known, roster writes and viewport re-asserts make no game-thread walk;
--   * the roster still lists the connected player and the viewport flag is still set;
--   * before the listen world is known, the roster falls back to the search and still works.
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
local gameThreadWalks = {}
local function gameWalkCount()
    local n = 0
    for _, v in pairs(gameThreadWalks) do n = n + v end
    return n
end
local noop = function() return nil end
local env = setmetatable({
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
        return {}
    end,
    FindFirstOf = function(name)
        if name == "GameEngine" then return engine end
        if name == "World" then return world end
        return nil
    end,
    StaticFindObject = noop, print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })

local exports = "\nreturn { serviceJoiners = serviceJoiners, netDriverValid = netDriverValid,"
    .. " disableWorldRendering = disableWorldRendering }\n"
local mod = assert(load(source .. exports, "main.lua", "t", env))()

local function controller(addr, serial, opts)
    opts = opts or {}
    local ps = uobj(addr + 1, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_" .. serial,
        { bOnlySpectator = false, GetPlayerName = function() return opts.name or "Player" end })
    return uobj(addr, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_" .. serial,
        { PlayerState = ps, IsLocalPlayerController = function() return opts.host or false end })
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

local hostPc = controller(1100, 20, { host = true })
local hal = controller(1200, 21, { name = "Hal" })
-- Hal is in the world (possessed): the join start driver, which searches while a joiner is
-- still pawnless, is not part of the steady state measured here
hal.Pawn = uobj(1300, "Player_C " .. LEVEL .. "Player_C_21")
pcs[1], pcs[2] = hostPc, hal
local f = assert(io.open(SERVER_DIR .. "\\login-identities.tsv", "w"))
f:write(table.concat({ tostring(NOW * 1000), "", "steam_76561198000000051", "steam_76561198000000051", "Hal", "", "" }, "\t"), "\n")
f:close()
conns[1] = uobj(9200, "IpConnection /Engine/Transient.IpConnection_21", { OwningActor = hal })

check("before the listen world is known, the roster falls back to the search and lists the player", function()
    os.remove(ROSTER)
    for t = 10, 22, 3 do mod.serviceJoiners(t) end
    local roster = readFile(ROSTER)
    assert(roster:find('"players":[{', 1, true), "roster has no player: " .. roster)
    assert((gameThreadWalks["IpNetDriver"] or 0) > 0, "expected the fallback search")
end)

check("the service loop finds the listen world (off the game thread)", function()
    assert(mod.netDriverValid() == true, "no listen world")
end)

check("with the listen world known, 40 service passes with a player on make no game-thread walk", function()
    gameThreadWalks = {}
    os.remove(ROSTER)
    for t = 30, 150, 3 do mod.serviceJoiners(t) end
    local n = gameWalkCount()
    local detail = {}
    for k, v in pairs(gameThreadWalks) do detail[#detail + 1] = k .. "=" .. v end
    assert(n == 0, "game-thread walks: " .. table.concat(detail, " "))
    local roster = readFile(ROSTER)
    assert(roster:find('"players":[{', 1, true), "roster lost the player: " .. roster)
end)

check("the viewport re-assert sets the flag with no game-thread walk", function()
    gameThreadWalks = {}
    viewport.bDisableWorldRendering = false
    for _ = 1, 5 do mod.disableWorldRendering() end
    assert(viewport.bDisableWorldRendering == true, "flag not set")
    assert(gameWalkCount() == 0, "game-thread walks: " .. tostring(gameThreadWalks["GameViewportClient"]))
end)

check("an idle server (host only) writes an empty roster with no game-thread walk", function()
    gameThreadWalks = {}
    conns[1] = nil
    pcs[2] = nil
    gm.NumPlayers = 1 -- the engine gave the seat back (a stuck count is the seat heal's job, not measured here)
    for t = 160, 400, 3 do mod.serviceJoiners(t) end
    local detail = {}
    for k, v in pairs(gameThreadWalks) do detail[#detail + 1] = k .. "=" .. v end
    assert(gameWalkCount() == 0, "game-thread walks on an idle server: " .. table.concat(detail, " "))
    assert(readFile(ROSTER):find('"players":[]', 1, true), "idle roster not empty: " .. readFile(ROSTER))
end)

print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
