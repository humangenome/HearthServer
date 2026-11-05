-- bw_fog v0.1.0: software map-fog reveal for the Hearth headless Bellwright host.
--
-- Bellwright keeps the authoritative map fog as a CPU byte array on the MapFog actor.
-- On a rendering host that array is refilled from a render-target readback; under
-- -nullrhi that readback is patched out, so exploration is never recorded, never saved
-- and never sent to a (re)joining client.  This mod stamps a revealed disc around every
-- remote player's pawn into that array through HearthFogReveal.dll, using the game's
-- own UMapViewComponent::GetViewCoordinates for the world->pixel mapping and
-- AMapFog::GetFogAtLocation as the readback self-check.  The game does the rest:
-- AMistMapFog saves the array, restores it on load, and streams it to every joiner.
--
-- Isolated UE4SS mod (own lua_State): a failure here cannot take bw_host down.
--
-- v0.1.3 (2026-10-14): a callback the game thread never runs no longer stops the reveal
-- for good (queued again after 120 s).  And no full object searches on the steady path.  v0.1.2 searched the
-- whole object list twice every 2 s on the game thread (FindAllOf for two controller
-- class names; the second found the same controllers), even with nobody on, and each
-- search froze the server for 65-110 ms.  The host runs a fixed 30 fps step, so every
-- frozen frame was game time lost: worlds ran at 92-96% of real time idle.  Now the
-- controllers are searched once (one class), kept by object path and resolved through
-- StaticFindObject (a hash lookup) each cycle, and searched again only when a new
-- controller is constructed, a kept one stops resolving (a leave or a travel), the map
-- fog actor changes, or every 30 s with players on (2 min with nobody on) as a safety
-- net.  Fog and map-view lookups are retried every 5th cycle while missing instead of
-- every cycle.  Stamping is unchanged.
--
-- v0.1.5 (2026-10-22): less game-thread work per cycle with players on, and a timing line.  The
-- 10/22 fleet reading found worlds losing 3-5 points of world speed per player (85% of real time
-- with four), in a stall every 2 s that lines up with this cycle.  Now:
--   * a timing line every stats_cycles cycles (ms per phase, worst cycle, the native call's own
--     microseconds) and a slow-cycle line (at most once a minute) when one cycle takes over
--     slow_cycle_ms.  os.clock is wall time under the Windows C runtime UE4SS is built with;
--   * the readback through the game's own fog reader runs only until the axis check has passed
--     once (or after 10 unusable reads), not after every stamp;
--   * the whole-map count (every pixel into two histograms) only at boot and every counts_every-th
--     stamp call, when HearthFogReveal.dll speaks API 2 (an older DLL keeps counting every call);
--   * a player is stamped again only after a real move: min_move_px defaults to a quarter of the
--     reveal radius (at least 2 px), so the trail of discs still overlaps with no gaps.
--
-- v0.1.6 (2026-10-25): the players come from the game's own player list.  The 10/24 lab
-- measured worlds at 91.7% of real time with two players and this mod on, 99.2% with it off;
-- v0.1.5's timing line put about 150 ms of every 2 s cycle (210 ms with three players) in the
-- player step, and a cycle with nobody left to stamp still took 148 ms while two departed
-- controllers failed their lookup.  The cost is the lookup by object path (StaticFindObject),
-- once per controller per cycle: cheap for the host's own controller, made early, and 50-70 ms
-- for a joiner's or a missing one (read from the lab timing; probe_lookup=1 in bw_fog.cfg times
-- the lookups once to confirm it on a server).  Now each cycle reads the fog actor's world ->
-- GameState -> PlayerArray -> each PlayerState's pawn: property reads on objects the game hands
-- over that frame, no object-list walk, no lookup by path, nothing kept between cycles but the
-- fog actor (kept since v0.1.0).  A player who leaves drops out of the list at logout, so a left
-- controller is no longer worked on.  If the list cannot be read on a build, the v0.1.5
-- controller search runs as before and the log says so.
local MOD_VERSION = "v0.1.6"
local DLL = ".\\ue4ss\\Mods\\bw_fog\\HearthFogReveal.dll"
local REQUEST = ".\\ue4ss\\Mods\\bw_fog\\fog-reveal-request.txt"
local STATUS = ".\\ue4ss\\Mods\\bw_fog\\fog-reveal-status.txt"
local CFG = ".\\ue4ss\\Mods\\bw_fog\\bw_fog.cfg"

local LOG = os.getenv("HEARTH_HOST_LOG") or os.getenv("BW_HOST_LOG")
if LOG and #LOG > 0 then LOG = LOG:gsub("bw_host%.log$", "bw_fog.log") end
if not LOG or #LOG == 0 or LOG:match("bw_host") then
    LOG = (os.getenv("LOCALAPPDATA") or "C:\\Temp") .. "\\bw_fog.log"
end

local function log(m)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("%H:%M:%S ") .. "[bw_fog] " .. tostring(m) .. "\r\n"); f:close() end
    end)
end
log("mod loaded " .. MOD_VERSION)

-- ---------------------------------------------------------------- config
local cfg = { test_fill = nil, radius_cm = 15000, value = 255, interval_ms = 2000, min_move_px = nil, test_stamp = nil, log_every = 60,
    rescan_cycles = 15, idle_rescan_cycles = 60, missing_retry_cycles = 5, stats_cycles = 300,
    counts_every = 30, slow_cycle_ms = 50, readback_tries = 10, probe_lookup = false }
pcall(function()
    local f = io.open(CFG, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = tostring(line):gsub("[\r\n]+$", ""):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "radius_cm" then cfg.radius_cm = tonumber(v) or cfg.radius_cm
        elseif k == "value" then cfg.value = tonumber(v) or cfg.value
        elseif k == "interval_ms" then cfg.interval_ms = tonumber(v) or cfg.interval_ms
        elseif k == "min_move_px" then cfg.min_move_px = tonumber(v) or cfg.min_move_px   -- unset = a quarter of the radius
        elseif k == "counts_every" then cfg.counts_every = math.max(0, tonumber(v) or cfg.counts_every)
        elseif k == "slow_cycle_ms" then cfg.slow_cycle_ms = math.max(1, tonumber(v) or cfg.slow_cycle_ms)
        elseif k == "readback_tries" then cfg.readback_tries = math.max(1, tonumber(v) or cfg.readback_tries)
        elseif k == "log_every" then cfg.log_every = tonumber(v) or cfg.log_every
        elseif k == "rescan_cycles" then cfg.rescan_cycles = math.max(1, tonumber(v) or cfg.rescan_cycles)
        elseif k == "idle_rescan_cycles" then cfg.idle_rescan_cycles = math.max(1, tonumber(v) or cfg.idle_rescan_cycles)
        elseif k == "missing_retry_cycles" then cfg.missing_retry_cycles = math.max(1, tonumber(v) or cfg.missing_retry_cycles)
        elseif k == "stats_cycles" then cfg.stats_cycles = math.max(1, tonumber(v) or cfg.stats_cycles)
        elseif k == "probe_lookup" then cfg.probe_lookup = (v == "1" or v == "true")
        elseif k == "test_fill" then cfg.test_fill = tonumber(v)
        elseif k == "test_stamp" then
            local x, y, z = v:match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
            if x then cfg.test_stamp = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            elseif v == "auto" then cfg.test_stamp = "auto" end
        end
    end
    f:close()
end)
log(string.format("config radius_cm=%s value=%s interval_ms=%s test_stamp=%s",
    tostring(cfg.radius_cm), tostring(cfg.value), tostring(cfg.interval_ms),
    (type(cfg.test_stamp) == "table") and (cfg.test_stamp.X .. "," .. cfg.test_stamp.Y .. "," .. cfg.test_stamp.Z) or tostring(cfg.test_stamp or "-")))

-- ---------------------------------------------------------------- helpers
local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function fullName(o)
    local s = "?"
    pcall(function() s = o:GetFullName() end)
    return tostring(s)
end
local function className(o)
    local s = "?"
    pcall(function() s = o:GetClass():GetFName():ToString() end)
    return tostring(s)
end
-- Every FindAllOf walks the whole object list (hundreds of thousands of objects).  Count
-- them so the stats line shows what the steady path costs.
local stats = { walks = 0, searches = 0, resolves = 0, stamps = 0 }
local function findAll(c)
    stats.walks = stats.walks + 1
    local ok, a = pcall(function() return FindAllOf(c) end)
    if ok and type(a) == "table" then return a end
    return {}
end
-- GetFullName() is "Class /Path.Outer:Sub.Name"; StaticFindObject wants the path.
local function pathOf(o)
    local fn = fullName(o)
    local path = fn:match("^%S+%s+(/%S.*)$")
    return path
end
local function resolve(path)
    stats.resolves = stats.resolves + 1
    local o = nil
    pcall(function() o = StaticFindObject(path) end)
    if valid(o) then return o end
    return nil
end
local function num(v)
    if type(v) == "number" then return v end
    if type(v) == "table" then
        for _, x in pairs(v) do if type(x) == "number" then return x end end
    end
    return nil
end
local function vec(v)
    if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x = v.X; y = v.Y; z = v.Z end)
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

-- ---------------------------------------------------------------- native
local native = nil
local function loadNative()
    if native then return true end
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        log("native unavailable: package.loadlib missing"); return false
    end
    local ok, fn = pcall(package.loadlib, DLL, "HearthFogReveal_Service")
    if ok and type(fn) == "function" then native = fn; log("native loaded path=" .. DLL); return true end
    log("native load failed path=" .. DLL .. " err=" .. tostring(fn)); return false
end

local function readStatus()
    local f = io.open(STATUS, "r")
    if not f then return { state = "missing" } end
    local st = {}
    for line in f:lines() do
        local k, v = tostring(line):gsub("[\r\n]+$", ""):match("^([%w_]+)=(.*)$")
        if k then st[k] = v end
    end
    f:close()
    return st
end

local function statusText(st)
    local keys = { "state", "error", "size", "stamps", "changed", "changed_permanent", "permanent", "revealed", "pixels", "hist0", "hist1", "counts", "num", "max", "actual", "api", "us" }
    local parts = {}
    for _, k in ipairs(keys) do if st[k] ~= nil then table.insert(parts, k .. "=" .. tostring(st[k])) end end
    return table.concat(parts, " ")
end

-- Write the request and run the native stamper.  stamps = { {cx,cy,r}, ... }
local fillPending = cfg.test_fill
-- API level of HearthFogReveal.dll, read from its status (an API 1 DLL never reports one and refuses
-- unknown request keys, so counts=0 is sent only once the DLL has said api=2).
local nativeApi = 1
-- timing for the stats period: ms per phase (os.clock deltas), native core microseconds from the DLL
local timing = { cycles = 0, busy = 0, total = 0, max = 0, lookup = 0, players = 0, roster = 0, native = 0, nativeUs = 0, check = 0,
    calls = 0, counted = 0, checks = 0 }
local lastSlowLogT = -1e9
local function clockMs() return os.clock() * 1000 end
local function runNative(fogAddr, fogSize, stamps, wantCounts)
    local t0 = clockMs()
    local f = io.open(REQUEST, "w")
    if not f then return { state = "error", error = "request_write" } end
    f:write("fog=" .. tostring(fogAddr) .. "\r\n")
    if fillPending and #stamps > 0 then f:write("fill=" .. tostring(fillPending) .. "\r\n"); log("TEST: filling whole fog array with " .. tostring(fillPending)); fillPending = nil end
    f:write("size=" .. tostring(fogSize) .. "\r\n")
    f:write("value=" .. tostring(cfg.value) .. "\r\n")
    for _, s in ipairs(stamps) do f:write(string.format("stamp=%d,%d,%d\r\n", s[1], s[2], s[3])) end
    if not wantCounts and nativeApi >= 2 then f:write("counts=0\r\n") end
    f:close()
    local ok, err = pcall(native)
    local st
    if not ok then st = { state = "error", error = "native_call " .. tostring(err) } else st = readStatus() end
    local api = tonumber(st.api)
    if api and api > nativeApi then nativeApi = api; log("native api=" .. api .. " (whole-map count every " .. cfg.counts_every .. " stamp calls)") end
    timing.calls = timing.calls + 1
    if st.counts ~= "skipped" then timing.counted = timing.counted + 1 end
    timing.native = timing.native + (clockMs() - t0)
    timing.nativeUs = timing.nativeUs + (tonumber(st.us) or 0)
    return st
end

-- ---------------------------------------------------------------- world lookups
local world = { fog = nil, fogAddr = nil, view = nil, size = nil, ratio = nil, coordShape = nil, swapAxes = false, swapChecked = false,
    fogMiss = 0, viewMiss = 0, fogWake = true, generation = 0, readbackTries = 0, readbackGaveUp = false }

local function findFog()
    if valid(world.fog) then
        if not world.size or world.size < 16 then pcall(function() world.size = world.fog.FogRenderTargetSize end) end
        return world.fog
    end
    if world.fog ~= nil then log("fog actor gone; searching again"); world.fogWake = true end
    world.fog = nil; world.view = nil; world.size = nil; world.ratio = nil; world.viewMiss = 0
    -- while there is no fog actor (menu, the travel map, a world still loading) search on a
    -- new-fog event or every missing_retry_cycles-th cycle, not every cycle
    world.fogMiss = world.fogMiss + 1
    if not world.fogWake and ((world.fogMiss - 1) % cfg.missing_retry_cycles) ~= 0 then return nil end
    world.fogWake = false
    local candidates = {}
    for _, o in ipairs(findAll("MistMapFog")) do if valid(o) and not fullName(o):find("Default__", 1, true) then table.insert(candidates, o) end end
    if #candidates == 0 then
        for _, tracker in ipairs(findAll("MapTrackerComponent")) do
            pcall(function()
                local fogs = tracker.MapFogs
                if fogs then
                    fogs:ForEach(function(_, elem)
                        local o = elem:get()
                        if valid(o) and not fullName(o):find("Default__", 1, true) then table.insert(candidates, o) end
                    end)
                end
            end)
        end
    end
    if #candidates == 0 then return nil end
    world.fog = candidates[1]
    world.fogMiss = 0
    world.generation = world.generation + 1
    pcall(function() world.fogAddr = world.fog:GetAddress() end)
    pcall(function() world.size = world.fog.FogRenderTargetSize end)
    log("fog actor " .. fullName(world.fog) .. " addr=" .. tostring(world.fogAddr) .. " size=" .. tostring(world.size) .. " candidates=" .. #candidates)
    return world.fog
end

local function findView(fog)
    if valid(world.view) then return world.view end
    world.view = nil
    world.viewMiss = world.viewMiss + 1
    if ((world.viewMiss - 1) % cfg.missing_retry_cycles) ~= 0 then return nil end
    local fogName = fullName(fog)
    local firstAny = nil
    for _, v in ipairs(findAll("MapViewComponent")) do
        if valid(v) and not fullName(v):find("Default__", 1, true) then
            local outer = nil
            pcall(function() outer = v:GetOuter() end)
            local outerName = outer and fullName(outer) or "?"
            if outerName == fogName then world.view = v; break end
            if not firstAny and outer and className(outer):find("MapFog") then firstAny = v end
        end
    end
    if not world.view then world.view = firstAny end
    if world.view then world.viewMiss = 0; log("map view " .. fullName(world.view)) else log("map view not found (will retry every " .. cfg.missing_retry_cycles .. " cycles)") end
    return world.view
end

-- Returns ok, x, y (view-space 0..1) using whichever out-param shape UE4SS exposes.
local function viewCoords(view, loc)
    if world.coordShape ~= "B" then
        local r = { pcall(function() return view:GetViewCoordinates(loc, false) end) }
        if r[1] and type(r[3]) == "number" and type(r[4]) == "number" then
            if not world.coordShape then world.coordShape = "A"; log("GetViewCoordinates returns (ok,x,y) shape=A") end
            return r[2] and true or false, r[3], r[4]
        end
        if not world.coordShape then
            local dump = {}
            for i = 1, #r do table.insert(dump, tostring(r[i])) end
            log("GetViewCoordinates shape A unusable: " .. table.concat(dump, " | "))
        end
    end
    local ox, oy = {}, {}
    local ok, res = pcall(function() return view:GetViewCoordinates(loc, false, ox, oy) end)
    local x, y = num(ox), num(oy)
    if ok and x and not y then
        -- UE4SS may deliver every out value through the first table: try named/indexed forms
        local nums = {}
        for k, v in pairs(ox) do if type(v) == "number" then table.insert(nums, { tostring(k), v }) end end
        table.sort(nums, function(a, b) return a[1] < b[1] end)
        if not world.coordShape then
            local dump = {}
            for _, kv in ipairs(nums) do table.insert(dump, kv[1] .. "=" .. tostring(kv[2])) end
            log("GetViewCoordinates first out table: " .. table.concat(dump, " ") .. " second table entries=" .. tostring(#nums))
        end
        if #nums >= 2 then x, y = nums[1][2], nums[2][2] end
    end
    if ok and x and y then
        if not world.coordShape then world.coordShape = "B"; log("GetViewCoordinates fills out tables shape=B") end
        return res and true or false, x, y
    end
    if not world.coordShape then
        log("GetViewCoordinates shape B unusable ok=" .. tostring(ok) .. " res=" .. tostring(res) .. " ox=" .. tostring(num(ox)) .. " oy=" .. tostring(num(oy)))
        world.coordShape = "none"
    end
    return false
end

local function fogAt(fog, loc)
    local r = { pcall(function() return fog:GetFogAtLocation(loc, false) end) }
    if r[1] and type(r[3]) == "number" then return r[3] end
    local out = {}
    local ok = pcall(function() return fog:GetFogAtLocation(loc, false, out) end)
    if ok then return num(out) end
    return nil
end

local function pixelOf(x, y, size)
    local cx = math.floor(size * x + 0.5)
    local cy = math.floor(size * y + 0.5)
    if world.swapAxes then cx, cy = cy, cx end
    return cx, cy
end

local function ensureRatio(fog)
    if world.ratio then return world.ratio end
    local ok, r = pcall(function() return fog:GetWorldToPixelRatio() end)
    if ok and type(r) == "number" and r > 0 then world.ratio = r; log(string.format("world-to-pixel ratio=%.8f px/cm (radius %d cm = %d px)", r, cfg.radius_cm, math.ceil(cfg.radius_cm * r))) end
    return world.ratio
end

-- ---------------------------------------------------------------- players
-- The player controllers, kept by object path between cycles.  A full search (one walk
-- of the object list) runs only when it is due: at start, when a new controller was
-- constructed (NotifyOnNewObject below), when a kept path stops resolving (a player left,
-- or a travel renamed the controller into the new world), when the fog actor changed,
-- or every rescan_cycles cycles with a remote player on (idle_rescan_cycles with nobody).
local CONTROLLER_CLASS = "MistOasisPlayerController"   -- FindAllOf includes subclasses (OasisPlayerController_C)
local track = { paths = {}, kept = {}, wake = true, sinceSearch = 0, remote = 0, generation = -1, hooked = false, keptLogged = false }

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

local function searchControllers(why)
    stats.searches = stats.searches + 1
    local paths, kept, seen = {}, {}, {}
    for _, pc in ipairs(findAll(CONTROLLER_CLASS)) do
        if valid(pc) and not fullName(pc):find("Default__", 1, true) then
            local path = pathOf(pc)
            if path and not seen[path] then
                seen[path] = true
                table.insert(paths, path)
                -- check once that the path resolves to this very object; if it does not, keep
                -- the object itself for this controller (checked with IsValid each cycle)
                local back = resolve(path)
                if not (back and addressOf(back) == addressOf(pc)) then
                    kept[path] = pc
                    if not track.keptLogged then track.keptLogged = true; log("path lookup did not return the controller (" .. path .. "); keeping the object instead") end
                end
            end
        end
    end
    track.kept = kept
    local changed = #paths ~= #track.paths
    if not changed then for i, p in ipairs(paths) do if track.paths[i] ~= p then changed = true; break end end end
    track.paths = paths
    track.wake = false
    track.sinceSearch = 0
    if changed then log("controllers " .. #paths .. " (search: " .. tostring(why) .. ")") end
end

local function controllerSearchDue()
    if track.wake then return "event" end
    if track.generation ~= world.generation then return "fog actor changed" end
    local every = (track.remote > 0) and cfg.rescan_cycles or cfg.idle_rescan_cycles
    if not track.hooked then every = math.min(every, cfg.missing_retry_cycles) end
    if track.sinceSearch >= every then return "periodic" end
    return nil
end

local lastPixel = {}   -- pawn full name -> {cx, cy}
local function remotePawnLocations()
    track.sinceSearch = track.sinceSearch + 1
    local why = controllerSearchDue()
    if why then track.generation = world.generation; searchControllers(why) end
    local out, remote, lost = {}, 0, false
    for _, path in ipairs(track.paths) do
        local pc = track.kept[path]
        if pc then
            if not valid(pc) then pc = nil end
        else
            pc = resolve(path)
        end
        if not pc then
            lost = true
        else
            local isLocal = true
            pcall(function() isLocal = pc:IsLocalPlayerController() end)
            if not isLocal then
                remote = remote + 1
                local pawn = nil
                pcall(function() pawn = pc.Pawn end)
                if valid(pawn) then
                    local loc = nil
                    pcall(function() loc = pawn:K2_GetActorLocation() end)
                    local v = vec(loc)
                    if v then table.insert(out, { key = addressOf(pawn) or fullName(pawn), loc = loc, v = v, pc = pc }) end
                end
            end
        end
    end
    track.remote = remote
    -- a kept controller no longer resolves: search again next cycle (once, not every cycle)
    if lost then track.wake = true end
    return out
end

-- A new controller (a joiner's login, or one rebuilt by a travel) wakes the search.  The
-- callback runs inside object construction: set a flag, touch nothing.  v0.1.4: registered from
-- the game-thread loop's first run (see the end of this file), not from this start-up chunk.
local function registerHooks()
    pcall(function()
        NotifyOnNewObject("/Script/Mist.MistOasisPlayerController", function() track.wake = true end)
        track.hooked = true
    end)
    pcall(function()
        NotifyOnNewObject("/Script/Mist.MistMapFog", function() world.fogWake = true end)
    end)
    log("new-controller hook " .. (track.hooked and "on" or "unavailable (searching every " .. cfg.missing_retry_cycles .. " cycles)"))
end

-- ---------------------------------------------------------------- roster (v0.1.6)
-- The players from the game's own list, read fresh every cycle on the game thread: the fog
-- actor's level -> its world -> GameState -> PlayerArray -> each PlayerState's pawn (PawnPrivate,
-- else its controller's Pawn).  The hidden host's PlayerState has no pawn, so it is never stamped;
-- a joiner is stamped once it has a pawn; a player who logs out leaves PlayerArray.  Returns nil
-- when the list cannot be read (the caller then uses the controller search above).
local roster = { route = nil, players = 0, switches = 0, probed = false, hostPc = nil }

local function field(o, k)
    local v = nil
    pcall(function() v = o[k] end)
    if valid(v) then return v end
    return nil
end

local function keyOf(o)
    local a = addressOf(o)
    if a then return a end
    return fullName(o)
end

local function worldOf(fog)
    local level = nil
    pcall(function() level = fog:GetOuter() end)
    if not valid(level) then return nil end
    local w = field(level, "OwningWorld")
    if w then return w end
    pcall(function() w = level:GetOuter() end)
    if valid(w) then return w end
    return nil
end

local function rosterPawns(fog)
    roster.hostPc = nil
    local w = worldOf(fog)
    local gs = w and field(w, "GameState")
    if not gs then return nil end
    local arr = nil
    pcall(function() arr = gs.PlayerArray end)
    if arr == nil then return nil end
    local states = {}
    local ok = pcall(function()
        arr:ForEach(function(_, elem)
            local ps = elem:get()
            if valid(ps) then table.insert(states, ps) end
        end)
    end)
    -- the hidden host's PlayerState is always in the list, so an empty one was not read right
    if not ok or #states == 0 then return nil end
    local out, remote = {}, 0
    for _, ps in ipairs(states) do
        local pc = field(ps, "Owner")
        local pawn = field(ps, "PawnPrivate")
        if not pawn and pc then pawn = field(pc, "Pawn") end
        local isLocal = false
        if pc then pcall(function() isLocal = pc:IsLocalPlayerController() end) end
        if isLocal then
            roster.hostPc = roster.hostPc or pc
        elseif pawn then
            remote = remote + 1
            local loc = nil
            pcall(function() loc = pawn:K2_GetActorLocation() end)
            local v = vec(loc)
            if v then table.insert(out, { key = keyOf(pawn), loc = loc, v = v, pc = pc }) end
        end
    end
    roster.players = #states
    track.remote = remote
    return out
end

-- probe_lookup=1 (lab only): once, with a remote player on, time the lookups v0.1.5 made every
-- cycle, so a server's own log shows what each one costs.  About a quarter of a second, once.
local function probeLookup(joinerPc)
    roster.probed = true
    local function timed(fn)
        local t = clockMs()
        local r = fn()
        return clockMs() - t, r
    end
    local jp = joinerPc and pathOf(joinerPc)
    local hp = roster.hostPc and pathOf(roster.hostPc)
    local jms, jo = timed(function() return jp and resolve(jp) end)
    local mms = timed(function() return jp and resolve(jp .. "_gone") end)
    local hms, ho = timed(function() return hp and resolve(hp) end)
    local fms, all = timed(function() return findAll(CONTROLLER_CLASS) end)
    log(string.format("probe lookup: StaticFindObject joiner controller %.1f ms (found=%s), missing path %.1f ms, host controller %.1f ms (found=%s); FindAllOf %s %.1f ms (%d)",
        jms, tostring(jo ~= nil), mms, hms, tostring(ho ~= nil), CONTROLLER_CLASS, fms, #(all or {})))
end

local function routeTo(r)
    if roster.route == r then return end
    roster.route = r
    roster.switches = roster.switches + 1
    if roster.switches > 10 then return end
    if r == "gamestate" then log("players from the game's player list (GameState.PlayerArray): no object searches, no lookups by path")
    else log("the game's player list is not readable here; finding controllers by search (the v0.1.5 path)") end
end

-- ---------------------------------------------------------------- main cycle
local booted = false
local cycles = 0
local lastLogT = 0
local lastSummary = ""

local function logStats()
    if cycles % cfg.stats_cycles ~= 0 then return end
    log(string.format("stats cycles=%d searches=%d walks=%d resolves=%d stamps=%d controllers=%d players=%d remote=%d route=%s",
        cycles, stats.searches, stats.walks, stats.resolves, stats.stamps, #track.paths, roster.players, track.remote, tostring(roster.route)))
end

-- One line per stats period, logged after the period's last cycle: wall ms on the game thread by phase;
-- native_core_ms is the DLL's own time inside native_ms (the rest is the request and status files).
local function logTiming()
    if cycles % cfg.stats_cycles ~= 0 then return end
    log(string.format("timing cycles=%d busy=%d total_ms=%.0f max_ms=%.0f lookup_ms=%.0f players_ms=%.0f roster_ms=%.0f native_ms=%.0f native_core_ms=%.1f check_ms=%.0f native_calls=%d counted=%d checks=%d route=%s",
        timing.cycles, timing.busy, timing.total, timing.max, timing.lookup, timing.players, timing.roster, timing.native, timing.nativeUs / 1000,
        timing.check, timing.calls, timing.counted, timing.checks, tostring(roster.route)))
    for k in pairs(timing) do timing[k] = 0 end
end

local stampCalls = 0   -- native calls that stamped something: every counts_every-th one also counts the whole map
local function cycle(ph)
    if not loadNative() then return end
    local t = clockMs()
    local fog = findFog()
    if not fog or not world.fogAddr or not world.size or world.size < 16 then
        ph.lookup = ph.lookup + (clockMs() - t)
        if cycles % 30 == 1 then log("waiting for MapFog actor (fog=" .. tostring(fog ~= nil) .. " size=" .. tostring(world.size) .. ")") end
        return
    end
    local view = findView(fog)
    if not view then ph.lookup = ph.lookup + (clockMs() - t); return end
    local ratio = ensureRatio(fog)
    ph.lookup = ph.lookup + (clockMs() - t)
    if not ratio then if cycles % 30 == 1 then log("GetWorldToPixelRatio unavailable") end return end
    local rpx = math.max(1, math.ceil(cfg.radius_cm * ratio))
    -- a real move: a quarter of the radius (at least 2 px) unless min_move_px is set; the discs still overlap
    local minMove = cfg.min_move_px or math.max(2, math.ceil(rpx / 4))

    if not booted then
        booted = true
        local st = runNative(world.fogAddr, world.size, {}, true)
        log("boot readback " .. statusText(st) .. " min_move_px=" .. minMove)
    end

    t = clockMs()
    local stamps, targets = {}, {}
    local pawns = rosterPawns(fog)
    if pawns then routeTo("gamestate") else routeTo("search"); pawns = remotePawnLocations() end
    ph.roster = ph.roster + (clockMs() - t)
    if cfg.probe_lookup and not roster.probed and roster.route == "gamestate" and #pawns > 0 then probeLookup(pawns[1].pc) end
    local seen = {}
    for _, p in ipairs(pawns) do
        seen[p.key] = true
        local ok, x, y = viewCoords(view, p.loc)
        if ok and x and y then
            local cx, cy = pixelOf(x, y, world.size)
            local last = lastPixel[p.key]
            if not last or math.abs(last[1] - cx) >= minMove or math.abs(last[2] - cy) >= minMove then
                table.insert(stamps, { cx, cy, rpx }); table.insert(targets, p)
                lastPixel[p.key] = { cx, cy }
            end
        end
    end
    -- forget players who are gone (a later object at the same address starts fresh)
    for k in pairs(lastPixel) do if not seen[k] then lastPixel[k] = nil end end
    if cfg.test_stamp == "auto" then
        -- canary without players: reveal around the first PlayerStart (else the fog actor itself)
        local anchor = nil
        for _, ps in ipairs(findAll("PlayerStart")) do if valid(ps) and not fullName(ps):find("Default__", 1, true) then anchor = ps; break end end
        anchor = anchor or fog
        local loc = nil
        pcall(function() loc = anchor:K2_GetActorLocation() end)
        local v = vec(loc)
        if v then cfg.test_stamp = v; log(string.format("test stamp anchor %s at %.0f,%.0f,%.0f", fullName(anchor), v.X, v.Y, v.Z)) else cfg.test_stamp = nil; log("test stamp: no anchor location") end
    end
    if type(cfg.test_stamp) == "table" then
        local ok, x, y = viewCoords(view, cfg.test_stamp)
        if ok and x and y then
            local cx, cy = pixelOf(x, y, world.size)
            table.insert(stamps, { cx, cy, rpx }); table.insert(targets, { key = "test", loc = cfg.test_stamp, v = cfg.test_stamp })
        elseif cycles % 30 == 1 then
            log("test stamp: coordinates unavailable ok=" .. tostring(ok) .. " x=" .. tostring(x) .. " y=" .. tostring(y))
        end
    end
    ph.players = ph.players + (clockMs() - t)
    if #stamps == 0 then return end

    stampCalls = stampCalls + 1
    ph.busy = true
    local st = runNative(world.fogAddr, world.size, stamps, cfg.counts_every > 0 and (stampCalls % cfg.counts_every) == 0)
    stats.stamps = stats.stamps + #stamps
    local summary = statusText(st)
    -- readback self-check through the game's own reader: on the first stamps decide the axis order, then
    -- stop (v0.1.5).  A test stamp (lab and canary config only) is always read back.
    t = clockMs()
    local checks = {}
    for i, p in ipairs(targets) do
      if p.key == "test" or (not world.swapChecked and not world.readbackGaveUp) then
        local f = fogAt(fog, p.loc)
        timing.checks = timing.checks + 1
        table.insert(checks, string.format("%s@(%d,%d)=%s", p.key == "test" and "test" or ("p" .. i), stamps[i][1], stamps[i][2], f and string.format("%.2f", f) or "?"))
        if not world.swapChecked and f ~= nil then
            world.swapChecked = true
            if f < 0.5 then
                world.swapAxes = true
                local s2 = stamps[i]; s2[1], s2[2] = s2[2], s2[1]
                local st2 = runNative(world.fogAddr, world.size, { s2 }, false)
                local f2 = fogAt(fog, p.loc)
                log(string.format("axis check: (x->col,y->row) read %.2f; swapped read %s -> %s", f, f2 and string.format("%.2f", f2) or "?", (f2 and f2 >= 0.5) and "using swapped axes" or "swap did not help, keeping swapped for review"))
                summary = summary .. " | swapped " .. statusText(st2)
            else
                log(string.format("axis check: (x->col,y->row) read %.2f -> mapping confirmed", f))
            end
        elseif not world.swapChecked and f == nil and p.key ~= "test" then
            world.readbackTries = world.readbackTries + 1
            if world.readbackTries >= cfg.readback_tries then
                world.readbackGaveUp = true
                log("readback: the game's fog reader gave no value " .. world.readbackTries .. " times; readback check off")
            end
        end
      end
    end
    if type(cfg.test_stamp) == "table" then
        local far = { X = cfg.test_stamp.X + 60000, Y = cfg.test_stamp.Y + 60000, Z = cfg.test_stamp.Z }
        local ff = fogAt(fog, far)
        table.insert(checks, "control+600m=" .. (ff and string.format("%.2f", ff) or "?"))
    end
    ph.check = ph.check + (clockMs() - t)
    if #checks == 0 then checks = { world.swapChecked and "done" or "off" } end
    local line = "stamp " .. summary .. " r=" .. rpx .. "px check=" .. table.concat(checks, " ")
    local now = os.time()
    if st.state ~= "ok" or line ~= lastSummary and (now - lastLogT) >= cfg.log_every or cycles <= 5 then
        log(line); lastLogT = now; lastSummary = line
    end
end

-- v0.1.4 (2026-10-18): one game-thread loop (LoopInGameThreadWithDelay, every interval_ms), registered
-- as the last UE4SS call of this file.  Until v0.1.3 a background loop (LoopAsync) queued each cycle
-- with ExecuteInGameThread, and in UE4SS b50986bd that call writes to the Lua stack the game thread is
-- running on with nothing locking the two: it could leave UE4SS's game-thread queue dead for the rest
-- of the session ("Ref was not function") or crash the game.  No background code here any more
-- (tests/host-thread-safety.test.lua).
local hooksRegistered = false
local function cycleOnGameThread()
    if not hooksRegistered then
        hooksRegistered = true
        registerHooks()
    end
    cycles = cycles + 1
    logStats()
    local ph = { lookup = 0, players = 0, roster = 0, check = 0, busy = false }
    local t0, n0 = clockMs(), timing.native
    local cok, cerr = pcall(cycle, ph)
    if not cok then log("cycle failed: " .. tostring(cerr)) end
    local ms, nativeMs = clockMs() - t0, timing.native - n0
    timing.cycles = timing.cycles + 1
    if ph.busy then timing.busy = timing.busy + 1 end
    timing.total = timing.total + ms
    if ms > timing.max then timing.max = ms end
    timing.lookup = timing.lookup + ph.lookup
    timing.players = timing.players + ph.players
    timing.roster = timing.roster + ph.roster
    timing.check = timing.check + ph.check
    if ms >= cfg.slow_cycle_ms and (t0 - lastSlowLogT) >= 60000 then
        lastSlowLogT = t0
        log(string.format("slow cycle %.0f ms: lookup %.0f players %.0f (roster %.0f) native %.0f check %.0f remote=%d route=%s", ms, ph.lookup, ph.players, ph.roster, nativeMs, ph.check, track.remote, tostring(roster.route)))
    end
    logTiming()
end
local loopOk, loopErr = pcall(LoopInGameThreadWithDelay, cfg.interval_ms, cycleOnGameThread)
log("game-thread loop registered=" .. tostring(loopOk) .. (loopOk and "" or (" err=" .. tostring(loopErr))))
