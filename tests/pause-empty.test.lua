-- Run from the repository root: lua5.4 tests/pause-empty.test.lua [path/to/bw_pause/main.lua]
-- Loads the bw_pause host mod against a stub UE4SS and drives its game-thread loop second by second.
-- Checks:
--   * nothing happens during the boot grace or while someone is connected;
--   * after the grace with nobody connected it asks for a save first and pauses only once bw_host has
--     taken the request (its marker gone); a request that is never taken never pauses;
--   * a connection lifts the pause on the next cycle; a rejoin inside the grace never pauses;
--   * the panel switch ("PauseWhenEmpty": false in appsettings.json) and Logs\bw_pause.off lift a pause
--     and keep it off; a save or a stop asked for while paused lifts it;
--   * connections that cannot be read lift a pause;
--   * a game mode that refuses SetGamePaused is paused through PauserPlayerState and lifted with ClearPause;
--   * a pause that never holds turns the mod off after three tries; an unpause that fails turns it off;
--   * no object-list walk and no lookup by path while running (one engine lookup, one CDO lookup).
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_pause/Scripts/main.lua"
local fh = assert(io.open(path, "r"))
local source = fh:read("*a")
fh:close()

local failures = 0
local function check(cond, label)
    if cond then print("ok - " .. label) else print("FAIL - " .. label); failures = failures + 1 end
end

local ROOT = "C:\\pkg"
local LOGDIR = ROOT .. "\\Logs"
local PAUSE_LOG = LOGDIR .. "\\bw_pause.log"
local STATUS = LOGDIR .. "\\bw_pause.status"
local OFF = LOGDIR .. "\\bw_pause.off"
local STOP = LOGDIR .. "\\bw_stop.marker"
local SAVE = LOGDIR .. "\\hearth_force_save_7777.marker"
local APPSETTINGS = ROOT .. "\\HearthServer\\appsettings.json"

local function makeWorld(opts)
    opts = opts or {}
    local W = { files = {}, now = 1792000000, loop = nil, walks = 0, finds = {}, engineLookups = 0 }
    if opts.cfg then W.files[".\\ue4ss\\Mods\\bw_pause\\bw_pause.cfg"] = opts.cfg end
    local function memfile(name, mode)
        local m = mode:sub(1, 1)
        if m == "r" then
            local data = W.files[name]
            if not data then return nil end
            local pos = 1
            return {
                read = function(_, what)
                    if what == "*l" then
                        local e = data:find("\n", pos, true) or (#data + 1)
                        local l = data:sub(pos, e - 1); pos = e + 1; return l
                    end
                    local r = data:sub(pos); pos = #data + 1; return r
                end,
                lines = function()
                    return function()
                        if pos > #data then return nil end
                        local e = data:find("\n", pos, true) or (#data + 1)
                        local l = data:sub(pos, e - 1); pos = e + 1; return l
                    end
                end,
                close = function() end,
            }
        end
        if m == "w" then W.files[name] = "" end
        if m == "a" then W.files[name] = W.files[name] or "" end
        return { write = function(_, x) W.files[name] = W.files[name] .. tostring(x) end, close = function() end }
    end
    local function obj(fields)
        local o = fields or {}
        o.__alive = true
        function o:IsValid() return self.__alive end
        return o
    end
    -- the world: viewport -> world -> net driver (client connections), persistent level -> world settings,
    -- game state (player array), authority game mode
    local conns = { n = 0 }
    function conns:GetArrayNum() return self.n end
    local ws = obj({ PauserPlayerState = nil })
    local level = obj({ WorldSettings = ws })
    local hostPc = obj({})
    function hostPc:IsLocalPlayerController() return true end
    local hostPs = obj({ Owner = hostPc })
    local players = { ForEach = function(_, fn) fn(1, { get = function() return hostPs end }) end }
    local gs = obj({ PlayerArray = players })
    local gm = obj({ bPauseable = not opts.notPauseable, clears = 0 })
    local nd = obj({ ClientConnections = conns })
    local world = obj({ NetDriver = nd, PersistentLevel = level, GameState = gs, AuthorityGameMode = gm, __paused = false })
    local vc = obj({ World = world })
    local engine = obj({ GameViewport = vc })
    function gm:ClearPause()
        self.clears = self.clears + 1
        if opts.stuckPause then return false end
        world.__paused = false; ws.PauserPlayerState = nil; return true
    end
    local statics = obj({ sets = 0, pauseSets = 0 })
    function statics:SetGamePaused(w, b)
        self.sets = self.sets + 1
        if b then self.pauseSets = self.pauseSets + 1 end
        if opts.neverHolds then return false end
        if b then
            if not gm.bPauseable then return false end
            w.__paused = true; ws.PauserPlayerState = hostPs
        elseif not opts.stuckPause then
            w.__paused = false; ws.PauserPlayerState = nil
        end
        return true
    end
    function statics:IsGamePaused(w)
        if opts.neverHolds then return false end
        return w.__paused or (ws.PauserPlayerState ~= nil)
    end
    -- PauserPlayerState writes from the mod: a plain field on the stub
    W.world, W.ws, W.gm, W.conns, W.statics, W.nd = world, ws, gm, conns, statics, nd

    local env = setmetatable({
        io = { open = memfile },
        os = setmetatable({
            getenv = function(k)
                if k == "HEARTH_HOST_LOG" then return LOGDIR .. "\\bw_host.log" end
                if k == "HEARTH_GAME_PORT" then return "7777" end
                return nil
            end,
            time = function() return W.now end,
            date = function() return "00:00:00 " end,
            clock = os.clock,
        }, { __index = os }),
        LoopInGameThreadWithDelay = function(ms, fn) W.loop = fn end,
        LoopAsync = function() error("bw_pause must not register a background loop") end,
        ExecuteInGameThread = function() error("bw_pause must not call ExecuteInGameThread") end,
        FindFirstOf = function(c)
            W.walks = W.walks + 1
            if c == "GameEngine" then W.engineLookups = W.engineLookups + 1; return engine end
            return nil
        end,
        FindAllOf = function() W.walks = W.walks + 1; return {} end,
        StaticFindObject = function(p)
            W.finds[p] = (W.finds[p] or 0) + 1
            if p == "/Script/Engine.Default__GameplayStatics" then return statics end
            return nil
        end,
        print = function() end,
    }, { __index = _G })
    assert(load(source, "bw_pause main.lua", "t", env))()
    assert(W.loop, "the mod registers one game-thread loop")
    -- bw_host stand-in: takes a save request (removes the marker) after takeAfter seconds, unless told not to
    W.takeAfter = opts.takeAfter or 3
    W.markerSeen = nil
    function W.step(n, each)
        for _ = 1, n or 1 do
            if each then each() end
            if W.files[SAVE] ~= nil and not opts.neverTake then
                W.markerSeen = W.markerSeen or W.now
                if W.now - W.markerSeen >= W.takeAfter then W.files[SAVE] = nil; W.markerSeen = nil end
            end
            W.loop()
            W.now = W.now + 1
        end
    end
    function W.paused() return W.world.__paused or W.ws.PauserPlayerState ~= nil end
    function W.log() return W.files[PAUSE_LOG] or "" end
    function W.status() return W.files[STATUS] or "" end
    return W
end

local BOOT, GRACE = 300, 120

-- 1. boot grace, then nobody: save first, pause once the save request is taken
do
    local W = makeWorld()
    W.step(BOOT - 5)
    check(not W.paused() and W.files[SAVE] == nil, "boot: nothing during the boot grace")
    W.step(6)
    check(W.files[SAVE] ~= nil and not W.paused(), "empty: asks for a save before pausing, not paused yet")
    check(W.log():find("asked the game to save before pausing") ~= nil, "empty: the save request is logged")
    W.step(5)
    check(W.paused(), "empty: paused once bw_host took the save request")
    check(W.log():find("world PAUSED: nobody connected for %d+ s, world saved %(via SetGamePaused%)") ~= nil, "empty: the pause is logged with its route")
    check(W.status():find("paused=1", 1, true) ~= nil, "empty: the status file says paused=1")
    -- a player connects: lifted on the next cycle
    W.conns.n = 1
    W.step(1)
    check(not W.paused(), "join: the pause is lifted on the first cycle with a connection")
    check(W.log():find("world running again: a player connected %(was paused %d+ s%)") ~= nil, "join: logged with the paused time")
    check(W.status():find("paused=0", 1, true) ~= nil, "join: the status file says paused=0")
    -- stays unpaused while connected
    W.step(600)
    check(not W.paused() and W.files[SAVE] == nil, "join: never paused or saved while someone is connected (600 s)")
    -- leaves, rejoins inside the grace: never paused
    W.conns.n = 0
    W.step(GRACE - 10)
    W.conns.n = 1
    W.step(5)
    W.conns.n = 0
    W.step(GRACE - 10)
    check(not W.paused() and W.files[SAVE] == nil, "rejoin: a rejoin inside the grace never pauses")
    W.step(20)
    check(W.paused(), "leave: paused again after a full grace with nobody")
    check(W.walks == 1 and W.engineLookups == 1, "cost: one engine lookup in " .. (BOOT + 1000) .. " s, no other walk (" .. W.walks .. ")")
    local paths = 0
    for p, n in pairs(W.finds) do if p ~= "/Script/Engine.Default__GameplayStatics" then paths = paths + n end end
    check(paths == 0 and (W.finds["/Script/Engine.Default__GameplayStatics"] or 0) == 1, "cost: one CDO lookup, no lookup by path")
end

-- 2. the switch: appsettings PauseWhenEmpty false lifts a pause and keeps it off; the off file too
do
    local W = makeWorld()
    W.step(BOOT + GRACE + 10)
    check(W.paused(), "switch: paused with the switch on (missing = on)")
    W.files[APPSETTINGS] = '{\n  "Hearth": {\n    "WorldName": "",\n    "PauseWhenEmpty": false\n  }\n}\n'
    W.step(31)
    check(not W.paused(), "switch: \"PauseWhenEmpty\": false lifts the pause within 30 s")
    check(W.log():find("world running again: switched off") ~= nil, "switch: logged")
    W.step(1000)
    check(not W.paused() and W.files[SAVE] == nil, "switch: off means no save request and no pause (1000 s)")
    W.files[APPSETTINGS] = '{ "Hearth": { "PauseWhenEmpty": true } }'
    W.step(GRACE + 40)
    check(W.paused(), "switch: back on, paused again after the grace")
    W.files[OFF] = ""
    W.step(31)
    check(not W.paused(), "off file: Logs\\bw_pause.off lifts the pause")
end

-- 3. a save or a stop asked for while paused lifts it
do
    local W = makeWorld()
    W.step(BOOT + GRACE + 10)
    W.files[STOP] = "1"
    W.step(1)
    check(not W.paused(), "stop: the stop marker lifts the pause")
    W.files[STOP] = nil
    W.step(GRACE + 10)
    check(W.paused(), "stop: paused again a grace later (the marker gone)")
    W.files[SAVE] = "x"      -- an operator's or the panel's save request
    W.markerSeen = nil
    W.step(1)
    check(not W.paused(), "save: an operator's save request lifts the pause")
end

-- 4. a save request that is never taken never pauses
do
    local W = makeWorld({ neverTake = true })
    W.step(BOOT + GRACE + 120)
    check(not W.paused(), "untaken save: no pause while bw_host has not taken the request")
    check(W.log():find("not taken in 90 s; not pausing") ~= nil, "untaken save: logged after save_wait_s")
end

-- 5. connections unreadable while paused: lifted
do
    local W = makeWorld()
    W.step(BOOT + GRACE + 10)
    W.world.NetDriver = nil
    W.step(1)
    check(not W.paused(), "blind: no net driver while paused lifts the pause")
    check(W.log():find("client connections not readable") ~= nil, "blind: logged")
end

-- 6. a game mode that refuses SetGamePaused: PauserPlayerState route, lifted with ClearPause
do
    local W = makeWorld({ notPauseable = true })
    W.step(BOOT + GRACE + 10)
    check(W.paused() and W.log():find("via PauserPlayerState") ~= nil, "refused: paused through PauserPlayerState")
    W.conns.n = 1
    W.step(1)
    check(not W.paused() and W.log():find("world running again: a player connected") ~= nil, "refused: lifted when a player connects")
end

-- 7. a pause that never holds turns the mod off after three tries; an unpause that fails turns it off
do
    local W = makeWorld({ neverHolds = true })
    for _ = 1, 4 do W.step(BOOT + GRACE + 10) end
    check(W.log():find("pause does not hold on this build") ~= nil, "never holds: the mod turns itself off after 3 tries")
    local n = 0
    for _ in W.log():gmatch("pause did not hold") do n = n + 1 end
    check(n == 3, "never holds: exactly three tries (" .. n .. ")")
end
do
    local W = makeWorld({ stuckPause = true })
    W.step(BOOT + GRACE + 10)
    W.conns.n = 1
    W.step(1)
    check(W.log():find("UNPAUSE FAILED") ~= nil, "stuck: a failed unpause is logged loudly and the mod turns itself off")
    local beforePause, beforeAll = W.statics.pauseSets, W.statics.sets
    W.step(300)
    local tries = W.statics.sets - beforeAll
    check(W.statics.pauseSets == beforePause, "stuck: no pause attempt after a failed unpause")
    check(tries >= 9 and tries <= 11, "stuck: the unpause is retried every 30 s, not every second (" .. tries .. " tries in 300 s)")
    local logged = 0
    for _ in W.log():gmatch("UNPAUSE FAILED") do logged = logged + 1 end
    check(logged <= 2, "stuck: the failure is logged on the first try and every 10th (" .. logged .. " lines)")
end

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all pause-when-empty checks passed")
