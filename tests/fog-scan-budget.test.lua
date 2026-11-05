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
-- v0.1.5 (cycle cost with players on, 2026-10-22):
--   * the game's fog reader is called only until the axis check has passed (or after readback_tries
--     unusable reads), a test stamp is always read back;
--   * an API 2 native gets counts=0 except at boot and every counts_every-th stamp call; an API 1
--     native (which refuses unknown keys) never gets it;
--   * a player is stamped again only after a real move (a quarter of the radius by default);
--   * a timing line every stats_cycles cycles and a rate-limited slow-cycle line.
-- v0.1.6 (players from the game's own list, 2026-10-25):
--   * with the list readable (fog actor -> level -> world -> GameState -> PlayerArray), no lookup by
--     path (StaticFindObject) and no object-list walk with players on, and a leave costs nothing;
--   * a player who logs out is dropped at once even while the game keeps the controller and pawn;
--   * the hidden host's pawnless PlayerState is never stamped;
--   * with the list unreadable (or read empty) the v0.1.5 search runs, and the log says so;
--   * probe_lookup=1 times the old lookups once, with a remote player on.
-- Sections 1-4 run on both routes.
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
    local W = { walks = 0, walkLog = {}, loops = {}, notify = {}, byPath = {}, controllers = {}, natives = {}, files = {},
        counted = {}, fogReads = 0, finds = 0, states = {} }
    if opts.cfg then W.files[".\\ue4ss\\Mods\\bw_fog\\bw_fog.cfg"] = opts.cfg end

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
    -- the game's player list: GameState.PlayerArray, a TArray of PlayerStates (UE4SS: ForEach(i, elem), elem:get())
    local playerArray = { ForEach = function(_, fn)
        if opts.playerArrayBroken then error("ForEach unavailable") end
        for i, ps in ipairs(W.states) do fn(i, { get = function() return ps end }) end
    end }
    W.gameState = uobj(4000, "MistOasisGameState_C " .. LEVEL .. "MistOasisGameState_C_0", { PlayerArray = playerArray })
    function W.newFog(level, addr)
        local fog = uobj(addr, "MistMapFog_C " .. level .. "MistMapFog_C_0", { FogRenderTargetSize = 512 })
        local worldName = level:match("^(.-):PersistentLevel%.$") or level
        local uworld = uobj(addr + 3, "World " .. worldName, { GameState = (not opts.noGameState) and W.gameState or nil })
        local ulevel = uobj(addr + 2, "Level " .. level:gsub("%.$", ""), { OwningWorld = uworld })
        function fog:GetOuter() return ulevel end
        function fog:GetWorldToPixelRatio() return 0.001 end
        function fog:GetFogAtLocation(loc, b)
            W.fogReads = W.fogReads + 1
            if opts.noReadback then error("reader unavailable") end
            return true, 1.0
        end
        local view = uobj(addr + 1, "MapViewComponent " .. level .. "MistMapFog_C_0.MapView")
        function view:GetOuter() return fog end
        function view:GetViewCoordinates(loc, b)
            if opts.slowView then local c = os.clock() + opts.slowView / 1000; while os.clock() < c do end end
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
        -- its PlayerState: Owner = the controller, PawnPrivate = the pawn (none for the hidden host)
        pc.__ps = uobj(8000 + serial * 10, "OasisPlayerState_C " .. level .. "OasisPlayerState_C_" .. serial, { Owner = pc, PawnPrivate = pc.Pawn })
        table.insert(W.states, pc.__ps)
        table.insert(W.controllers, pc)
        W.register(pc)
        return pc
    end
    -- logout: the PlayerState leaves the game's list; the controller and pawn may linger
    function W.logout(pc)
        for i, ps in ipairs(W.states) do if ps == pc.__ps then table.remove(W.states, i); break end end
        pc.__ps.__alive = false
    end
    function W.removeController(pc)
        W.logout(pc)
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
                local skip = req:find("counts=0", 1, true) ~= nil
                table.insert(W.counted, not skip)
                local status = "state=ok\nstamps=" .. n .. "\n"
                -- an API 2 DLL reports its level and time; an API 1 DLL refuses the unknown counts key
                if opts.api then status = status .. (skip and "counts=skipped\n" or "revealed=7\npixels=262144\n") .. "api=2\nus=1500\n"
                elseif skip then status = "state=error\nerror=request_key\n" end
                W.files[".\\ue4ss\\Mods\\bw_fog\\fog-reveal-status.txt"] = status
            end
        end },
        -- v0.1.4: one game-thread loop, no background loop and no ExecuteInGameThread
        LoopInGameThreadWithDelay = function(ms, fn) table.insert(W.loops, fn) end,
        LoopAsync = function() W.asyncLoops = (W.asyncLoops or 0) + 1 end,
        ExecuteInGameThread = function() error("bw_fog must not call ExecuteInGameThread") end,
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
        StaticFindObject = function(p) W.finds = W.finds + 1; return W.byPath[p] end,
        print = function() end,
    }, { __index = _G })
    assert(load(source, "bw_fog main.lua", "t", env))()
    assert(#W.loops == 1, "the mod registers one game-thread loop")
    assert((W.asyncLoops or 0) == 0, "the mod registers a background loop")
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

-- Sections 1-4 run twice: players from the game's list (v0.1.6), and with that list unreadable (the
-- v0.1.5 controller search, which v0.1.6 falls back to).
local function routeSections(base, route)
    local function with(extra)
        local t = {}
        for k, v in pairs(base) do t[k] = v end
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end
    local search = route == "search"
    local function check2(cond, label) check(cond, "[" .. route .. "] " .. label) end
-- 1. idle host: the hidden host's own controller, nobody else
do
    local check = check2
    local W = makeWorld(with())
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
    local check = check2
    local W = makeWorld(with())
    W.newController(0, true)
    W.cycles(30)
    local pc = W.newController(1, false)
    W.fire("/Script/Mist.MistOasisPlayerController")
    local n0 = #W.natives
    W.cycles(1)
    check(W.stampsSince(n0) == 1, "joiner: stamped on the first cycle after the controller was constructed")
    local w0, n1 = W.walks, #W.natives
    W.cycles(300, function() pc.Pawn.__loc.X = pc.Pawn.__loc.X + 8000 end)   -- 8 px a cycle: a real move
    local per = (W.walks - w0) / 300
    check(per <= 1 / 14, string.format("joiner: %.3f walks per cycle with a player on (budget 0.071)", per))
    check(W.stampsSince(n1) == 300, "joiner: stamped every cycle it moved (" .. W.stampsSince(n1) .. "/300)")
    W.removeController(pc)
    local w1 = W.walks
    W.cycles(2)
    -- the search route searches once after a leave; the game's list needs no search at all
    local want = search and 1 or 0
    check(W.walks - w1 == want, "leave: " .. want .. " search(es) (" .. (W.walks - w1) .. ")")
    local w2 = W.walks
    W.cycles(40)
    check(W.walks - w2 == 0, "leave: no further searches in the next 40 cycles (" .. (W.walks - w2) .. ")")
end

-- 3. two players, then a travel: new fog actor, controllers renamed into the new world
do
    local check = check2
    local W = makeWorld(with())
    W.newController(0, true)
    local a = W.newController(1, false)
    local b = W.newController(2, false)
    W.cycles(10, function() a.Pawn.__loc.Y = a.Pawn.__loc.Y + 8000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 8000 end)
    local n0 = #W.natives
    W.cycles(5, function() a.Pawn.__loc.Y = a.Pawn.__loc.Y + 8000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 8000 end)
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
    W.cycles(3, function() a.Pawn.__loc.Y = a.Pawn.__loc.Y + 8000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 8000 end)
    check(W.fog ~= fog0 and W.stampsSince(n1) >= 4, "travel: both players stamped again in the new world (" .. W.stampsSince(n1) .. " stamps in 3 cycles)")
end

-- 4. without the new-controller hook a joiner is still found within a few cycles
do
    local check = check2
    local W = makeWorld(with({ noHook = true }))
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
end
routeSections({}, "gamestate")
routeSections({ noGameState = true }, "search")

local LOGF = "C:\\Temp\\bw_fog.log"
local function logHas(W, pat) return (W.files[LOGF] or ""):find(pat) ~= nil end
local function logCount(W, pat) local n = 0; for _ in (W.files[LOGF] or ""):gmatch(pat) do n = n + 1 end; return n end
local function walker(pc, step) return function() pc.Pawn.__loc.X = pc.Pawn.__loc.X + step end end

-- 5. readback: the game's fog reader runs only until the axis check has passed
do
    local W = makeWorld()
    W.newController(0, true)
    local a = W.newController(1, false)
    local b = W.newController(2, false)
    W.cycles(100, function() a.Pawn.__loc.X = a.Pawn.__loc.X + 8000; b.Pawn.__loc.Y = b.Pawn.__loc.Y + 8000 end)
    check(W.stampsSince(0) >= 190, "readback: both players stamped while moving (" .. W.stampsSince(0) .. " stamps in 100 cycles)")
    check(W.fogReads == 1, "readback: the game's fog reader ran once, for the axis check (" .. W.fogReads .. " reads in 100 cycles; v0.1.4: one per stamp)")
    check(logHas(W, "mapping confirmed"), "readback: the axis check passed and was logged")
end
do
    local W = makeWorld({ noReadback = true })
    W.newController(0, true)
    local a = W.newController(1, false)
    W.cycles(60, walker(a, 8000))
    -- each try asks the reader in both call shapes UE4SS may expose: 10 tries = 20 calls
    check(W.fogReads == 20, "readback: an unusable reader is tried readback_tries (10) times, then left alone (" .. W.fogReads .. " reader calls)")
    check(logHas(W, "readback check off"), "readback: giving up is logged")
    check(W.stampsSince(0) == 60, "readback: stamping goes on without it (" .. W.stampsSince(0) .. "/60)")
end
do
    local W = makeWorld({ cfg = "test_stamp=1000,1000,0\n" })
    W.newController(0, true)
    W.cycles(20)
    -- the test stamp (lab and canary only) is read back every stamp call, plus its 600 m control
    check(W.fogReads == 40, "readback: a test stamp is always read back (" .. W.fogReads .. " reads in 20 cycles, 40 expected)")
end

-- 6. whole-map count: only at boot and every counts_every-th stamp call, and only with an API 2 native
do
    local W = makeWorld({ api = true })
    W.newController(0, true)
    local a = W.newController(1, false)
    W.cycles(91, walker(a, 8000))
    local calls, counted, skipped = #W.counted, 0, 0
    for _, c in ipairs(W.counted) do if c then counted = counted + 1 else skipped = skipped + 1 end end
    check(W.counted[1] == true, "counts: the boot call counts the whole map")
    -- calls: boot + 91 stamp calls; counted: boot + stamp calls 30, 60, 90.  The boot call runs first in the
    -- first cycle and its status says api=2, so the first stamp call already skips the count.
    check(calls == 92 and counted == 4 and skipped == 88, string.format("counts: %d calls, %d counted, %d skipped (92 / 4 / 88 expected)", calls, counted, skipped))
    check(logHas(W, "native api=2"), "counts: the native's API level is logged")
end
do
    local W = makeWorld()   -- API 1 native: no api in its status, refuses unknown keys
    W.newController(0, true)
    local a = W.newController(1, false)
    W.cycles(40, walker(a, 8000))
    local skipped = 0
    for _, c in ipairs(W.counted) do if not c then skipped = skipped + 1 end end
    check(skipped == 0, "counts: an API 1 native never gets counts=0 (" .. skipped .. ")")
    check(not logHas(W, "request_key"), "counts: no refused request")
end

-- 7. a real move: a quarter of the reveal radius (15 px here, so 4 px), unless min_move_px is set
do
    local W = makeWorld()
    W.newController(0, true)
    local still = W.newController(1, false)
    local slow = W.newController(2, false)
    local fast = W.newController(3, false)
    W.cycles(2)
    local n0 = #W.natives
    W.cycles(100, function() slow.Pawn.__loc.X = slow.Pawn.__loc.X + 2000; fast.Pawn.__loc.X = fast.Pawn.__loc.X + 8000 end)
    -- 100 fast stamps + 50 slow stamps (2 px a cycle reaches 4 px every other cycle) + 0 for the one standing still
    check(W.stampsSince(n0) == 150, "move: a standing player is not stamped again, a 2 px/cycle walker every other cycle, an 8 px/cycle one every cycle (" .. W.stampsSince(n0) .. "/150)")
    check(logHas(W, "min_move_px=4"), "move: the boot line names the threshold (4 px for a 15 px radius)")
end
do
    local W = makeWorld({ cfg = "min_move_px=1\n" })
    W.newController(0, true)
    local slow = W.newController(1, false)
    W.cycles(2)
    local n0 = #W.natives
    W.cycles(50, walker(slow, 2000))
    check(W.stampsSince(n0) == 50, "move: min_move_px=1 in bw_fog.cfg gives back the v0.1.4 behaviour (" .. W.stampsSince(n0) .. "/50)")
end

-- 8. timing: a line every stats_cycles cycles; a slow cycle is logged, at most once a minute
do
    local W = makeWorld({ api = true })
    W.newController(0, true)
    local a = W.newController(1, false)
    W.cycles(301, walker(a, 8000))
    check(logCount(W, "timing cycles=300 busy=%d+ total_ms=") == 1, "timing: one timing line after 300 cycles")
    local line = (W.files[LOGF] or ""):match("timing [^\r\n]*") or ""
    -- cycles 1-300: the boot call plus 300 stamp calls; counted = boot + stamp calls 30, 60 ... 300
    check(line:find("busy=300") and line:find("native_calls=301") and line:find("counted=11") and line:find("native_core_ms=451.5") ~= nil,
        "timing: the line counts native calls, whole-map counts and the native's own time (" .. line .. ")")
end
do
    local W = makeWorld({ slowView = 60 })
    W.newController(0, true)
    local a = W.newController(1, false)
    W.cycles(5, walker(a, 8000))
    check(logCount(W, "slow cycle %d+ ms: lookup") == 1, "timing: five slow cycles in a row give one slow-cycle line (" .. logCount(W, "slow cycle") .. ")")
    check(logHas(W, "slow cycle %d+ ms: lookup %d+ players [6-9]%d"), "timing: the slow-cycle line puts the time in the players phase")
end

-- 9. v0.1.6: players from the game's own list
local function moveAll(list, step) return function() for _, pc in ipairs(list) do pc.Pawn.__loc.X = pc.Pawn.__loc.X + step end end end
do
    local W = makeWorld()
    W.newController(0, true)
    local a = W.newController(1, false)
    local b = W.newController(2, false)
    W.cycles(5, moveAll({ a, b }, 8000))
    local f0, w0, n0 = W.finds, W.walks, #W.natives
    W.cycles(295, moveAll({ a, b }, 8000))
    check(W.finds - f0 == 0, "list: no lookup by path in 295 cycles with two players on (" .. (W.finds - f0) .. "; v0.1.5 made 3 a cycle)")
    check(W.walks - w0 == 0, "list: no object-list walk in 295 cycles with two players on (" .. (W.walks - w0) .. ")")
    check(W.stampsSince(n0) == 590, "list: both players stamped every cycle they moved (" .. W.stampsSince(n0) .. "/590)")
    check(logHas(W, "players from the game's player list"), "list: the route is logged")
    check(logHas(W, "stats cycles=300 [^\r\n]*players=3 remote=2 route=gamestate"), "list: the stats line names players, remote and the route")
    check(logHas(W, "timing cycles=300 [^\r\n]*roster_ms=%d+[^\r\n]*route=gamestate"), "list: the timing line carries the roster time and the route")
    -- b logs out; the game keeps its controller and pawn for minutes (the 10/24 lab: 7.5 + 2.5 min)
    W.logout(b)
    local n1 = #W.natives
    W.cycles(300, moveAll({ a, b }, 8000))
    check(W.stampsSince(n1) == 300, "list: a player who logged out is not stamped while the game keeps the controller and pawn (" .. W.stampsSince(n1) .. "/300)")
    check(logHas(W, "stats cycles=600 [^\r\n]*players=2 remote=1 route=gamestate"), "list: after the logout the stats line counts one remote player")
end
do
    -- the hidden host never has a pawn; a local controller with one is not stamped either
    local W = makeWorld()
    local host = W.newController(0, true)
    W.cycles(100)
    check(W.stampsSince(0) == 0 and W.finds == 0, "list: the hidden host alone is never stamped and nothing is looked up (" .. W.stampsSince(0) .. " stamps, " .. W.finds .. " lookups)")
    local pawn = W.uobj(9999, "Player_C " .. W.level .. "Player_C_99")
    function pawn:K2_GetActorLocation() return { X = 5000, Y = 0, Z = 0 } end
    host.__ps.PawnPrivate = pawn
    W.cycles(10)
    check(W.stampsSince(0) == 0, "list: a local controller's pawn is not stamped (" .. W.stampsSince(0) .. ")")
end
do
    -- no GameState: the v0.1.5 search, logged; an empty list and a broken ForEach count as unreadable too
    for _, case in ipairs({ { noGameState = true, label = "no GameState" }, { playerArrayBroken = true, label = "ForEach fails" }, { empty = true, label = "empty list" } }) do
        local W = makeWorld(case)
        W.newController(0, true)
        local a = W.newController(1, false)
        if case.empty then W.states = {} end
        W.cycles(20, moveAll({ a }, 8000))
        check(W.stampsSince(0) >= 19 and W.finds > 0, "fallback (" .. case.label .. "): the joiner is stamped through the controller search (" .. W.stampsSince(0) .. " stamps, " .. W.finds .. " lookups)")
        check(logHas(W, "not readable here; finding controllers by search"), "fallback (" .. case.label .. "): the log says so")
    end
end
do
    -- probe_lookup=1: once, with a remote player on: three lookups and one search, one line
    local W = makeWorld({ cfg = "probe_lookup=1\n" })
    W.newController(0, true)
    W.cycles(10)
    check(W.finds == 0 and not logHas(W, "probe lookup"), "probe: nothing while nobody is on")
    local a = W.newController(1, false)
    local f0, w0 = W.finds, W.walks
    W.cycles(50, moveAll({ a }, 8000))
    check(W.finds - f0 == 3 and W.walks - w0 == 1, "probe: three lookups and one search, once (" .. (W.finds - f0) .. " / " .. (W.walks - w0) .. ")")
    check(logCount(W, "probe lookup: StaticFindObject joiner controller [%d.]+ ms %(found=true%), missing path [%d.]+ ms, host controller [%d.]+ ms %(found=true%); FindAllOf") == 1,
        "probe: one line with the joiner, missing and host lookups and the search")
end

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all fog scan budget checks passed")
