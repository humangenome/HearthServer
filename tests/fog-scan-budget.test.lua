-- Run from the repository root: lua5.4 tests/fog-scan-budget.test.lua [path/to/bw_fog/main.lua]
-- Loads the bw_fog mod against a stub UE4SS and counts full object searches (FindAllOf calls,
-- each one a walk of the whole object list on the game thread) per 2 s cycle.
-- bw_fog v0.1.2 made two walks every cycle, even with nobody on, which froze the server for
-- 130-215 ms every 2 s; on the fixed 30 fps step that was 4-8% of the world's time.
-- Checks:
--   * idle (host only): at most one walk per idle_rescan_cycles once settled;
--   * a joiner is found on the cycle after its controller is constructed and stamped every
--     cycle it moves, with at most one walk per rescan_cycles while it stays;
--   * a leave costs one search, then nothing;
--   * a travel (new fog actor, controllers renamed into the new world) finds the players again;
--   * without the new-controller hook it still finds joiners within a few cycles.
-- Mocked engine; it checks the mod's bookkeeping, not a retail server.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_fog/Scripts/main.lua"
local fh = assert(io.open(path, "r"))
local source = fh:read("*a")
fh:close()

local failures = 0
local function check(cond, label)
    if cond then print("ok - " .. label) else print("FAIL - " .. label); failures = failures + 1 end
end

local function makeWorld(opts)
    opts = opts or {}
    local W = { walks = 0, walkLog = {}, loops = {}, notify = {}, byPath = {}, controllers = {}, natives = {}, files = {} }

    -- in-memory files for the mod's log, cfg, request and status files
    local function memfile(name, mode)
        if mode:sub(1, 1) == "r" then
            local data = W.files[name]
            if not data then return nil end
            local pos = 1
            return {
                lines = function()
                    return function()
                        if pos > #data then return nil end
                        local e = data:find("\n", pos, true) or (#data + 1)
                        local line = data:sub(pos, e - 1)
                        pos = e + 1
                        return line
                    end
                end,
                read = function() local r = data:sub(pos); pos = #data + 1; return r end,
                close = function() end,
            }
        end
        if mode:sub(1, 1) == "w" then W.files[name] = "" end
        if mode:sub(1, 1) == "a" then W.files[name] = W.files[name] or "" end
        return { write = function(_, x) W.files[name] = W.files[name] .. tostring(x) end, close = function() end }
    end
    local stubIo = { open = memfile }

    local function uobj(addr, fullName, fields)
        local o = fields or {}
        o.__addr, o.__name, o.__alive = addr, fullName, true
        function o:IsValid() return self.__alive end
        function o:GetAddress() return self.__addr end
        function o:GetFullName() return self.__name end
        function o:GetClass()
            local cls = self.__name:match("^(%S+)")
            return { GetFName = function() return { ToString = function() return cls end } end }
        end
        return o
    end
    W.uobj = uobj
    local function pathOf(o) return o.__name:match("^%S+%s+(/%S.*)$") end
    function W.register(o) W.byPath[pathOf(o)] = o end
    function W.unregister(o) W.byPath[pathOf(o)] = nil end

    local LEVEL = "/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08:PersistentLevel."
    W.level = LEVEL
    function W.newFog(level, addr)
        local fog = uobj(addr, "MistMapFog_C " .. level .. "MistMapFog_C_0", { FogRenderTargetSize = 512 })
        function fog:GetWorldToPixelRatio() return 0.001 end
        function fog:GetFogAtLocation(loc, b) return true, 1.0 end
        local view = uobj(addr + 1, "MapViewComponent " .. level .. "MistMapFog_C_0.MapView")
        function view:GetOuter() return fog end
        function view:GetViewCoordinates(loc, b)
            return true, (loc.X + 256000) / 512000, (loc.Y + 256000) / 512000
        end
        W.fog, W.view = fog, view
        W.register(fog); W.register(view)
        return fog
    end
    W.newFog(LEVEL, 5000)

    function W.newController(serial, isLocal, level)
        level = level or LEVEL
        local pc = uobj(7000 + serial * 10, "OasisPlayerController_C " .. level .. "OasisPlayerController_C_" .. serial)
        pc.__local = isLocal
        function pc:IsLocalPlayerController() return self.__local end
        if not isLocal then
            local pawn = uobj(7001 + serial * 10, "Player_C " .. level .. "Player_C_" .. serial)
            pawn.__loc = { X = 1000 * serial, Y = 0, Z = 0 }
            function pawn:K2_GetActorLocation() return { X = self.__loc.X, Y = self.__loc.Y, Z = self.__loc.Z } end
            pc.Pawn = pawn
        end
        table.insert(W.controllers, pc)
        W.register(pc)
        return pc
    end
    function W.removeController(pc)
        pc.__alive = false
        if pc.Pawn then pc.Pawn.__alive = false end
        W.unregister(pc)
        for i, c in ipairs(W.controllers) do if c == pc then table.remove(W.controllers, i); break end end
    end
    function W.fire(cls) for _, cb in ipairs(W.notify[cls] or {}) do cb({}) end end

    local env = setmetatable({
        io = stubIo,
        os = setmetatable({ getenv = function() return nil end }, { __index = os }),
        package = { loadlib = function()
            return function()
                local req = W.files[".\\ue4ss\\Mods\\bw_fog\\fog-reveal-request.txt"] or ""
                local n = 0
                for _ in req:gmatch("stamp=") do n = n + 1 end
                table.insert(W.natives, n)
                W.files[".\\ue4ss\\Mods\\bw_fog\\fog-reveal-status.txt"] = "state=ok\nstamps=" .. n .. "\n"
            end
        end },
        LoopAsync = function(ms, fn) table.insert(W.loops, fn) end,
        ExecuteInGameThread = function(fn) fn() end,
        NotifyOnNewObject = function(cls, cb)
            if opts.noHook and cls:find("PlayerController", 1, true) then error("hook unavailable") end
            W.notify[cls] = W.notify[cls] or {}; table.insert(W.notify[cls], cb)
        end,
        FindAllOf = function(cls)
            W.walks = W.walks + 1
            W.walkLog[cls] = (W.walkLog[cls] or 0) + 1
            if cls == "MistMapFog" then return (W.fog and W.fog.__alive) and { W.fog } or nil end
            if cls == "MapViewComponent" then return (W.view and W.view.__alive) and { W.view } or nil end
            -- UE4SS FindAllOf includes subclasses: both controller names return the same objects
            if cls == "MistOasisPlayerController" or cls == "OasisPlayerController_C" or cls == "PlayerController" then
                local out = {}
                for _, c in ipairs(W.controllers) do table.insert(out, c) end
                return out
            end
            return nil
        end,
        StaticFindObject = function(p) return W.byPath[p] end,
        print = function() end,
    }, { __index = _G })
    assert(load(source, "bw_fog main.lua", "t", env))()
    assert(#W.loops == 1, "the mod registers one LoopAsync")
    function W.cycles(n, each)
        for i = 1, n do
            if each then each(i) end
            W.loops[1]()
        end
    end
    function W.stampsSince(k)
        local s = 0
        for i = k + 1, #W.natives do s = s + W.natives[i] end
        return s
    end
    return W
end

-- 1. idle host: the hidden host's own controller, nobody else
do
    local W = makeWorld()
    W.newController(0, true)
    W.cycles(20)
    local w0 = W.walks
    W.cycles(600)
    local per = (W.walks - w0) / 600
    check(per <= 1 / 50, string.format("idle: %.3f walks per cycle over 600 cycles (budget 0.020)", per))
    check(W.stampsSince(0) == 0, "idle: nothing stamped")
end

-- 2. a joiner, staying ten minutes, moving every cycle; then leaving
do
    local W = makeWorld()
    W.newController(0, true)
    W.cycles(30)
    local pc = W.newController(1, false)
    W.fire("/Script/Mist.MistOasisPlayerController")
    local n0 = #W.natives
    W.cycles(1)
    check(W.stampsSince(n0) == 1, "joiner: stamped on the first cycle after the controller was constructed")
    local w0, n1 = W.walks, #W.natives
    W.cycles(300, function() pc.Pawn.__loc.X = pc.Pawn.__loc.X + 2000 end)
    local per = (W.walks - w0) / 300
    check(per <= 1 / 14, string.format("joiner: %.3f walks per cycle with a player on (budget 0.071)", per))
    check(W.stampsSince(n1) == 300, "joiner: stamped every cycle it moved (" .. W.stampsSince(n1) .. "/300)")
    W.removeController(pc)
    local w1 = W.walks
    W.cycles(2)
    check(W.walks - w1 == 1, "leave: one search (" .. (W.walks - w1) .. ")")
    local w2 = W.walks
    W.cycles(40)
    check(W.walks - w2 == 0, "leave: no further searches in the next 40 cycles (" .. (W.walks - w2) .. ")")
end

-- 3. two players, then a travel: new fog actor, controllers renamed into the new world
do
    local W = makeWorld()
    W.newController(0, true)
    local a = W.newController(1, false)
    local b = W.newController(2, false)
    W.cycles(10, function() a.Pawn.__loc.Y = a.Pawn.__loc.Y + 2000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 2000 end)
    local n0 = #W.natives
    W.cycles(5, function() a.Pawn.__loc.Y = a.Pawn.__loc.Y + 2000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 2000 end)
    check(W.stampsSince(n0) == 10, "two players: both stamped every cycle (" .. W.stampsSince(n0) .. "/10)")
    -- travel: the old fog dies, the transition map has none for a while, then the new world's fog arrives
    W.fog.__alive = false; W.view.__alive = false; W.unregister(W.fog); W.unregister(W.view)
    local fog0 = W.fog
    W.fog, W.view = nil, nil
    local ISLAND = "/Game/Mist/Maps/Excursion/ExcursionMed/ExcursionMed.ExcursionMed:PersistentLevel."
    for _, c in ipairs({ a, b }) do
        W.unregister(c); W.unregister(c.Pawn)
        c.__name = c.__name:gsub("/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08:PersistentLevel.", ISLAND)
        c.Pawn.__name = c.Pawn.__name:gsub("/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08.Karvenia_08:PersistentLevel.", ISLAND)
        W.register(c); W.register(c.Pawn)
    end
    local w0 = W.walks
    W.cycles(12)
    local transitWalks = W.walks - w0
    -- each fog search is two walks (MistMapFog, then MapTrackerComponent) when nothing is found;
    -- v0.1.2 searched every cycle
    check(transitWalks <= 6, "travel: searches while no fog actor exists are spaced out (" .. transitWalks .. " walks in 12 cycles)")
    W.newFog(ISLAND, 6000)
    W.fire("/Script/Mist.MistMapFog")
    local n1 = #W.natives
    W.cycles(3, function() a.Pawn.__loc.Y = a.Pawn.__loc.Y + 2000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 2000 end)
    check(W.fog ~= fog0 and W.stampsSince(n1) >= 4, "travel: both players stamped again in the new world (" .. W.stampsSince(n1) .. " stamps in 3 cycles)")
end

-- 4. without the new-controller hook a joiner is still found within a few cycles
do
    local W = makeWorld({ noHook = true })
    W.newController(0, true)
    W.cycles(30)
    local w0 = W.walks
    W.cycles(100)
    local per = (W.walks - w0) / 100
    check(per <= 1 / 4, string.format("no hook, idle: %.3f walks per cycle (budget 0.250)", per))
    local pc = W.newController(1, false)
    local n0, found = #W.natives, nil
    for i = 1, 10 do
        pc.Pawn.__loc.X = pc.Pawn.__loc.X + 2000
        W.cycles(1)
        if W.stampsSince(n0) > 0 then found = i; break end
    end
    check(found ~= nil and found <= 6, "no hook: joiner stamped within " .. tostring(found) .. " cycles (budget 6)")
end

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all fog scan budget checks passed")
