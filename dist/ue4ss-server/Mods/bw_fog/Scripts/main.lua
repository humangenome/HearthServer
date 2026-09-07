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
local MOD_VERSION = "v0.1.2"
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
local cfg = { test_fill = nil, radius_cm = 15000, value = 255, interval_ms = 2000, min_move_px = 1, test_stamp = nil, log_every = 60 }
pcall(function()
    local f = io.open(CFG, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = tostring(line):gsub("[\r\n]+$", ""):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "radius_cm" then cfg.radius_cm = tonumber(v) or cfg.radius_cm
        elseif k == "value" then cfg.value = tonumber(v) or cfg.value
        elseif k == "interval_ms" then cfg.interval_ms = tonumber(v) or cfg.interval_ms
        elseif k == "min_move_px" then cfg.min_move_px = tonumber(v) or cfg.min_move_px
        elseif k == "log_every" then cfg.log_every = tonumber(v) or cfg.log_every
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
local function findAll(c)
    local ok, a = pcall(function() return FindAllOf(c) end)
    if ok and type(a) == "table" then return a end
    return {}
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
    local keys = { "state", "error", "size", "stamps", "changed", "changed_permanent", "permanent", "revealed", "pixels", "hist0", "hist1", "num", "max", "actual" }
    local parts = {}
    for _, k in ipairs(keys) do if st[k] ~= nil then table.insert(parts, k .. "=" .. tostring(st[k])) end end
    return table.concat(parts, " ")
end

-- Write the request and run the native stamper.  stamps = { {cx,cy,r}, ... }
local fillPending = cfg.test_fill
local function runNative(fogAddr, fogSize, stamps)
    local f = io.open(REQUEST, "w")
    if not f then return { state = "error", error = "request_write" } end
    f:write("fog=" .. tostring(fogAddr) .. "\r\n")
    if fillPending and #stamps > 0 then f:write("fill=" .. tostring(fillPending) .. "\r\n"); log("TEST: filling whole fog array with " .. tostring(fillPending)); fillPending = nil end
    f:write("size=" .. tostring(fogSize) .. "\r\n")
    f:write("value=" .. tostring(cfg.value) .. "\r\n")
    for _, s in ipairs(stamps) do f:write(string.format("stamp=%d,%d,%d\r\n", s[1], s[2], s[3])) end
    f:close()
    local ok, err = pcall(native)
    if not ok then return { state = "error", error = "native_call " .. tostring(err) } end
    return readStatus()
end

-- ---------------------------------------------------------------- world lookups
local world = { fog = nil, fogAddr = nil, view = nil, size = nil, ratio = nil, coordShape = nil, swapAxes = false, swapChecked = false }

local function findFog()
    if valid(world.fog) then return world.fog end
    world.fog = nil; world.view = nil; world.size = nil; world.ratio = nil
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
    pcall(function() world.fogAddr = world.fog:GetAddress() end)
    pcall(function() world.size = world.fog.FogRenderTargetSize end)
    log("fog actor " .. fullName(world.fog) .. " addr=" .. tostring(world.fogAddr) .. " size=" .. tostring(world.size) .. " candidates=" .. #candidates)
    return world.fog
end

local function findView(fog)
    if valid(world.view) then return world.view end
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
    if world.view then log("map view " .. fullName(world.view)) else log("map view not found (MapViewComponent count=" .. #findAll("MapViewComponent") .. ")") end
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
local lastPixel = {}   -- pawn full name -> {cx, cy}
local function remotePawnLocations()
    local out = {}
    for _, cls in ipairs({ "OasisPlayerController_C", "MistOasisPlayerController" }) do
        for _, pc in ipairs(findAll(cls)) do
            if valid(pc) and not fullName(pc):find("Default__", 1, true) then
                local isLocal = true
                pcall(function() isLocal = pc:IsLocalPlayerController() end)
                if not isLocal then
                    local pawn = nil
                    pcall(function() pawn = pc.Pawn end)
                    if valid(pawn) then
                        local loc = nil
                        pcall(function() loc = pawn:K2_GetActorLocation() end)
                        local v = vec(loc)
                        if v then table.insert(out, { key = fullName(pawn), loc = loc, v = v }) end
                    end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- main cycle
local booted = false
local cycles = 0
local lastLogT = 0
local lastSummary = ""
local queued = false

local function cycle()
    cycles = cycles + 1
    if not loadNative() then return end
    local fog = findFog()
    if not fog or not world.fogAddr or not world.size or world.size < 16 then
        if cycles % 30 == 1 then log("waiting for MapFog actor (fog=" .. tostring(fog ~= nil) .. " size=" .. tostring(world.size) .. ")") end
        return
    end
    local view = findView(fog)
    if not view then return end
    local ratio = ensureRatio(fog)
    if not ratio then if cycles % 30 == 1 then log("GetWorldToPixelRatio unavailable") end return end
    local rpx = math.max(1, math.ceil(cfg.radius_cm * ratio))

    if not booted then
        booted = true
        local st = runNative(world.fogAddr, world.size, {})
        log("boot readback " .. statusText(st))
    end

    local stamps, targets = {}, {}
    for _, p in ipairs(remotePawnLocations()) do
        local ok, x, y = viewCoords(view, p.loc)
        if ok and x and y then
            local cx, cy = pixelOf(x, y, world.size)
            local last = lastPixel[p.key]
            if not last or math.abs(last[1] - cx) >= cfg.min_move_px or math.abs(last[2] - cy) >= cfg.min_move_px then
                table.insert(stamps, { cx, cy, rpx }); table.insert(targets, p)
                lastPixel[p.key] = { cx, cy }
            end
        end
    end
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
    if #stamps == 0 then return end

    local st = runNative(world.fogAddr, world.size, stamps)
    local summary = statusText(st)
    -- readback self-check through the game's own reader; on the first stamp decide the axis order
    local checks = {}
    for i, p in ipairs(targets) do
        local f = fogAt(fog, p.loc)
        table.insert(checks, string.format("%s@(%d,%d)=%s", p.key == "test" and "test" or ("p" .. i), stamps[i][1], stamps[i][2], f and string.format("%.2f", f) or "?"))
        if not world.swapChecked and f ~= nil then
            world.swapChecked = true
            if f < 0.5 then
                world.swapAxes = true
                local s2 = stamps[i]; s2[1], s2[2] = s2[2], s2[1]
                local st2 = runNative(world.fogAddr, world.size, { s2 })
                local f2 = fogAt(fog, p.loc)
                log(string.format("axis check: (x->col,y->row) read %.2f; swapped read %s -> %s", f, f2 and string.format("%.2f", f2) or "?", (f2 and f2 >= 0.5) and "using swapped axes" or "swap did not help, keeping swapped for review"))
                summary = summary .. " | swapped " .. statusText(st2)
            else
                log(string.format("axis check: (x->col,y->row) read %.2f -> mapping confirmed", f))
            end
        end
    end
    if type(cfg.test_stamp) == "table" then
        local far = { X = cfg.test_stamp.X + 60000, Y = cfg.test_stamp.Y + 60000, Z = cfg.test_stamp.Z }
        local ff = fogAt(fog, far)
        table.insert(checks, "control+600m=" .. (ff and string.format("%.2f", ff) or "?"))
    end
    local line = "stamp " .. summary .. " r=" .. rpx .. "px check=" .. table.concat(checks, " ")
    local now = os.time()
    if st.state ~= "ok" or line ~= lastSummary and (now - lastLogT) >= cfg.log_every or cycles <= 5 then
        log(line); lastLogT = now; lastSummary = line
    end
end

LoopAsync(cfg.interval_ms, function()
    if queued then return false end
    queued = true
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            local cok, cerr = pcall(cycle)
            if not cok then log("cycle failed: " .. tostring(cerr)) end
            queued = false
        end)
    end)
    if not ok then log("queue failed: " .. tostring(err)); queued = false end
    return false
end)
