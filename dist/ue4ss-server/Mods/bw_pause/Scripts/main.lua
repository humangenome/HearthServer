-- bw_pause v0.1.0: pause the Bellwright world while nobody is connected (Hearth host).
--
-- A Hearth server runs the world all the time, so food spoils and bandits raid while every
-- player is away. Bellwright's own co-op only runs while its host
-- plays. This mod pauses the world with the engine's own pause once nobody has been connected
-- for a grace period, after asking the game to save, and lifts the pause the moment a client
-- connects (a joiner connects seconds before it logs in, so the world runs before they spawn).
-- Single-player Bellwright pauses through the same engine pause, so its clock, spoilage and
-- raids already know how to wait.
--
-- Isolated UE4SS mod (own lua_State, own log): a failure here cannot take bw_host down. One
-- game-thread loop, registered as the last UE4SS call of this file; no background code
-- (tests/host-thread-safety.test.lua). Every cycle reads fresh objects the game hands over:
-- the engine (looked up once, it lives as long as the process), its viewport's world, that
-- world's net driver and its client connections. No lookup by path, no object-list walk while
-- running.
--
-- Off switches: the panel's Server Config switch writes "PauseWhenEmpty": false into
-- HearthServer\appsettings.json (re-read every setting_every_s); Logs\bw_pause.off turns it off at
-- once for one server; removing "bw_pause : 1" from mods.txt turns it off everywhere. Off while
-- paused lifts the pause.
--
-- Safety: never stays paused blind. If the connections cannot be read, a save or a stop is asked
-- for (bw_host's force-save marker, the launcher's stop marker), or the switch goes off, the
-- pause is lifted. The world is saved before every pause: no pause until bw_host has taken the
-- save request (its marker is gone).
local MOD_VERSION = "v0.1.0"
local CFG = ".\\ue4ss\\Mods\\bw_pause\\bw_pause.cfg"

local function getenv_file(envName, filePath, default)
    local v = os.getenv(envName)
    if v and #v > 0 then return v end
    local f = io.open(filePath, "r")
    if f then
        local s = f:read("*l"); f:close()
        if s and #s > 0 then return (s:gsub("%s+$", "")) end
    end
    return default
end
local GAME_PORT = getenv_file("HEARTH_GAME_PORT", "C:\\Windows\\Temp\\hearth_game_port.txt", "7777")

local HOST_LOG = os.getenv("HEARTH_HOST_LOG") or os.getenv("BW_HOST_LOG") or ""
local LOG_DIR = HOST_LOG:match("^(.*)[/\\][^/\\]+$")
local LOG = LOG_DIR and (LOG_DIR .. "\\bw_pause.log") or ((os.getenv("LOCALAPPDATA") or "C:\\Temp") .. "\\bw_pause.log")
local ROOT = HOST_LOG:match("^(.*)[\\/][Ll]ogs[\\/][^\\/]+$")
local APPSETTINGS = os.getenv("HEARTH_SERVER_DIR")
APPSETTINGS = (APPSETTINGS and #APPSETTINGS > 0) and (APPSETTINGS .. "\\appsettings.json")
    or (ROOT and (ROOT .. "\\HearthServer\\appsettings.json")) or nil
local OFF_FILE = LOG_DIR and (LOG_DIR .. "\\bw_pause.off") or nil
local STATUS_FILE = LOG_DIR and (LOG_DIR .. "\\bw_pause.status") or nil
local STOP_MARKER = LOG_DIR and (LOG_DIR .. "\\bw_stop.marker") or nil
-- the force-save markers bw_host serves (see its serviceForcedSave): beside the host log, and the
-- Windows Temp fallback; bw_host removes them once the save is queued on the game thread
local SAVE_MARKER_NAME = "hearth_force_save_" .. tostring(GAME_PORT) .. ".marker"
local SAVE_MARKERS = {}
if LOG_DIR then SAVE_MARKERS[#SAVE_MARKERS + 1] = LOG_DIR .. "\\" .. SAVE_MARKER_NAME end
SAVE_MARKERS[#SAVE_MARKERS + 1] = "C:\\Windows\\Temp\\" .. SAVE_MARKER_NAME

local function log(m)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("%H:%M:%S ") .. "[bw_pause] " .. tostring(m) .. "\r\n"); f:close() end
    end)
end
log("mod loaded " .. MOD_VERSION .. " port=" .. tostring(GAME_PORT))

-- ---------------------------------------------------------------- config
local cfg = { grace_s = 120, boot_grace_s = 300, save_wait_s = 90, setting_every_s = 30, interval_ms = 1000,
    status_every_s = 60, stats_every_s = 600, max_failures = 3 }
pcall(function()
    local f = io.open(CFG, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = tostring(line):gsub("[\r\n]+$", ""):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and cfg[k] ~= nil and tonumber(v) then cfg[k] = math.max(0, tonumber(v)) end
    end
    f:close()
end)
log(string.format("config grace_s=%d boot_grace_s=%d save_wait_s=%d", cfg.grace_s, cfg.boot_grace_s, cfg.save_wait_s))

-- ---------------------------------------------------------------- helpers
local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function field(o, k)
    local v = nil
    pcall(function() v = o[k] end)
    if valid(v) then return v end
    return nil
end
local function exists(path)
    if not path then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end
local function arrayCount(arr)
    if arr == nil then return nil end
    local n = nil
    pcall(function() n = arr:GetArrayNum() end)
    if type(n) == "number" then return n end
    pcall(function() n = #arr end)
    if type(n) == "number" then return n end
    return nil
end

-- the panel's switch: "PauseWhenEmpty": false in appsettings.json turns it off; missing = on
local function settingOn()
    if not APPSETTINGS then return true end
    local f = io.open(APPSETTINGS, "r")
    if not f then return true end
    local text = f:read("*a") or ""
    f:close()
    local v = text:match('"PauseWhenEmpty"%s*:%s*(%a+)')
    if v and v:lower() == "false" then return false end
    return true
end

local function saveOrStopAsked()
    for _, p in ipairs(SAVE_MARKERS) do if exists(p) then return true end end
    return exists(STOP_MARKER)
end

local function requestSave()
    local path = SAVE_MARKERS[1]
    local ok = false
    pcall(function()
        local f = io.open(path, "w")
        if f then f:write(tostring(os.time())); f:close(); ok = true end
    end)
    return ok
end

-- ---------------------------------------------------------------- engine and world
local state = { paused = false, pausedSince = nil, lastPeopleT = os.time(), bootT = os.time(), savingSince = nil,
    enabled = true, settingT = -1e9, failures = 0, disabled = false, engine = nil, engineT = -1e9, statics = nil,
    pauses = 0, pausedTotal = 0, statsT = os.time(), statusT = -1e9, conns = nil, route = nil,
    unpauseRetryT = nil, unpauseFails = 0 }

local function engineObj()
    if valid(state.engine) then return state.engine end
    state.engine = nil
    local now = os.time()
    if now - state.engineT < 60 then return nil end
    state.engineT = now
    pcall(function() state.engine = FindFirstOf("GameEngine") end)
    if valid(state.engine) then return state.engine end
    state.engine = nil
    return nil
end

local function currentWorld()
    local eng = engineObj()
    if not eng then return nil end
    local vc = field(eng, "GameViewport")
    return vc and field(vc, "World") or nil
end

local function statics()
    if valid(state.statics) then return state.statics end
    pcall(function() state.statics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    if valid(state.statics) then return state.statics end
    state.statics = nil
    return nil
end

local function isPaused(world)
    local gs = statics()
    local r = nil
    if gs then pcall(function() r = gs:IsGamePaused(world) end) end
    if type(r) == "boolean" then return r end
    -- the engine's own rule (UWorld::IsPaused): a pauser player state is set
    local ws = field(field(world, "PersistentLevel") or {}, "WorldSettings")
    if ws then return field(ws, "PauserPlayerState") ~= nil end
    return nil
end

local function hostPlayerState(world)
    local gs = field(world, "GameState")
    local arr = nil
    pcall(function() arr = gs.PlayerArray end)
    local found = nil
    pcall(function()
        arr:ForEach(function(_, elem)
            local ps = elem:get()
            local pc = field(ps, "Owner")
            local isLocal = false
            if pc then pcall(function() isLocal = pc:IsLocalPlayerController() end) end
            if isLocal and not found then found = ps end
        end)
    end)
    return found
end

local function writeStatus(why)
    if not STATUS_FILE then return end
    pcall(function()
        local f = io.open(STATUS_FILE, "w")
        if not f then return end
        f:write(string.format("paused=%d\r\nsince=%s\r\nenabled=%d\r\nconnections=%s\r\npauses=%d\r\nupdated=%d\r\nwhy=%s\r\n",
            state.paused and 1 or 0, tostring(state.pausedSince or 0), (state.enabled and not state.disabled) and 1 or 0,
            tostring(state.conns), state.pauses, os.time(), tostring(why or "")))
        f:close()
    end)
end

local function pauseWorld(world, why)
    local gs = statics()
    local route = "none"
    if gs then pcall(function() gs:SetGamePaused(world, true) end) end
    if isPaused(world) then
        route = "SetGamePaused"
    else
        -- the game mode refused (not pauseable): set what AGameModeBase::SetPause would have set
        local ws = field(field(world, "PersistentLevel") or {}, "WorldSettings")
        local ps = hostPlayerState(world)
        if ws and ps then pcall(function() ws.PauserPlayerState = ps end) end
        if isPaused(world) then route = "PauserPlayerState" end
    end
    if route == "none" then
        state.failures = state.failures + 1
        log("pause did not hold (" .. tostring(why) .. "); failures=" .. state.failures)
        if state.failures >= cfg.max_failures then
            state.disabled = true
            log("pause does not hold on this build; bw_pause stays off until the next start")
        end
        writeStatus("pause failed")
        return false
    end
    state.paused, state.pausedSince, state.route = true, os.time(), route
    state.pauses = state.pauses + 1
    log("world PAUSED: " .. tostring(why) .. " (via " .. route .. ")")
    writeStatus(why)
    return true
end

local function unpauseWorld(world, why)
    local gs = statics()
    if gs then pcall(function() gs:SetGamePaused(world, false) end) end
    if isPaused(world) then
        local gm = field(world, "AuthorityGameMode")
        if gm then pcall(function() gm:ClearPause() end) end
    end
    if isPaused(world) then
        local ws = field(field(world, "PersistentLevel") or {}, "WorldSettings")
        if ws then pcall(function() ws.PauserPlayerState = nil end) end
    end
    local still = isPaused(world)
    if still then
        -- never pause again this session, and keep trying to lift this one every 30 s
        state.disabled = true
        state.unpauseFails = state.unpauseFails + 1
        state.unpauseRetryT = os.time() + 30
        if state.unpauseFails == 1 or state.unpauseFails % 10 == 0 then
            log("UNPAUSE FAILED (" .. tostring(why) .. ", try " .. state.unpauseFails .. "): the world still reads paused; no more pauses this session, retrying every 30 s")
        end
        writeStatus("unpause failed")
        return false
    end
    state.unpauseRetryT = nil
    local secs = state.pausedSince and (os.time() - state.pausedSince) or 0
    state.pausedTotal = state.pausedTotal + secs
    state.paused, state.pausedSince = false, nil
    log(string.format("world running again: %s (was paused %d s)", tostring(why), secs))
    writeStatus(why)
    return true
end

-- lift the pause, but after a failed try only every 30 s
local function lift(world, why)
    if state.unpauseRetryT and os.time() < state.unpauseRetryT then return end
    unpauseWorld(world, why)
end

-- ---------------------------------------------------------------- the cycle
local function cycle()
    local now = os.time()
    if now - state.settingT >= cfg.setting_every_s then
        state.settingT = now
        local on = settingOn() and not exists(OFF_FILE)
        if on ~= state.enabled then log("switch " .. (on and "on" or "off")) end
        state.enabled = on
    end
    local world = currentWorld()
    if not world then return end
    local nd = field(world, "NetDriver")
    local conns = nil
    if nd then
        local arr = nil
        pcall(function() arr = nd.ClientConnections end)
        conns = arrayCount(arr)
    end
    state.conns = conns
    if now - state.statusT >= cfg.status_every_s then state.statusT = now; writeStatus("status") end
    if now - state.statsT >= cfg.stats_every_s then
        local total = state.pausedTotal + (state.pausedSince and (now - state.pausedSince) or 0)
        log(string.format("stats: paused=%s pauses=%d paused_total_s=%d since start %d s ago, enabled=%s", tostring(state.paused),
            state.pauses, total, now - state.bootT, tostring(state.enabled and not state.disabled)))
        state.statsT = now
    end

    if conns == nil then
        if state.paused then lift(world, "client connections not readable") end
        return
    end
    if conns > 0 then
        state.lastPeopleT = now
        state.savingSince = nil
        if state.paused then lift(world, "a player connected") end
        return
    end
    -- nobody connected
    if state.paused then
        if not state.enabled or state.disabled then lift(world, state.disabled and "turned off" or "switched off")
        elseif saveOrStopAsked() then
            lift(world, "a save or stop was asked for")
            state.lastPeopleT = now
        end
        return
    end
    if not state.enabled or state.disabled then state.savingSince = nil; return end
    if now - state.bootT < cfg.boot_grace_s or now - state.lastPeopleT < cfg.grace_s then return end
    if not state.savingSince then
        if saveOrStopAsked() then return end   -- someone else's save or a stop is under way
        if requestSave() then
            state.savingSince = now
            log(string.format("nobody connected for %d s: asked the game to save before pausing", now - state.lastPeopleT))
        end
        return
    end
    -- our save request: pause once bw_host has taken it (its marker is gone)
    if saveOrStopAsked() then
        if now - state.savingSince >= cfg.save_wait_s then
            log("the save request was not taken in " .. cfg.save_wait_s .. " s; not pausing, will ask again later")
            state.savingSince = nil
            state.lastPeopleT = now
        end
        return
    end
    state.savingSince = nil
    pauseWorld(world, string.format("nobody connected for %d s, world saved", now - state.lastPeopleT))
end

local function cycleOnGameThread()
    local ok, err = pcall(cycle)
    if not ok then log("cycle failed: " .. tostring(err)) end
end
local loopOk, loopErr = pcall(LoopInGameThreadWithDelay, cfg.interval_ms, cycleOnGameThread)
log("game-thread loop registered=" .. tostring(loopOk) .. (loopOk and "" or (" err=" .. tostring(loopErr))))
