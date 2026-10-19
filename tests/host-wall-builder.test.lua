-- Run from the repository root: lua5.4 tests/host-wall-builder.test.lua
-- Executes the real spline hooks and wall build-site service of bw_host against a
-- mocked engine that behaves like build 24840601: a wall piece only becomes a build
-- site when the first player controller has a player character. Proves ordering,
-- restore and safety only; the retail proof is a remote player's placement.
local file = assert(io.open(arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua", "r"))
local source = file:read("*a")
file:close()
local start = assert(source:find("do\nlocal sw =", 1, true), "spline hook block not found")

local tmpdir = os.tmpname()
os.remove(tmpdir)
assert(os.execute("mkdir -p '" .. tmpdir .. "'"))
local saveFile = tmpdir .. "/TEMP_auto.sav"
local logFile = tmpdir .. "/bw_host.log"
local offMarker = tmpdir .. "\\bw_wallfix.off" -- the mod joins the log folder with a backslash

local passed = 0
local function check(name, body)
    body()
    passed = passed + 1
    print("ok " .. passed .. " - " .. name)
end

-- ---------------------------------------------------------------- mock engine
local nextAddr = 1000
local function newObj(name, classes)
    nextAddr = nextAddr + 8
    local o = { name = name, classes = classes or {}, alive = true, addr = nextAddr }
    function o:IsValid() return self.alive end
    function o:GetAddress() return self.addr end
    function o:IsA(cls) return self.classes[cls.path] == true end
    function o:GetFullName() return self.name end
    return o
end
local classes = {}
for _, p in ipairs({ "/Script/Mist.MistWallBuildingActor", "/Script/Mist.MistPlaceable", "/Script/Mist.MistPlayer" }) do
    classes[p] = { path = p, IsValid = function() return true end }
end
local function array(items)
    return {
        items = items,
        GetArrayNum = function(self) return #self.items end,
        ForEach = function(self, fn) for i, v in ipairs(self.items) do fn(i, { get = function() return v end }) end end,
    }
end

local world -- rebuilt per scenario
local function newWorld(opts)
    opts = opts or {}
    local w = { byPath = {}, logs = {}, clearFails = opts.clearFails, invalidFails = opts.invalidFails, pawnReads = {} }
    local hostPc = newObj("OasisPlayerController_C /Game/Map.Map:PersistentLevel.OasisPlayerController_C_0", {})
    local pawnSlot = opts.hostPawn
    setmetatable(hostPc, {
        __index = function(_, k) if k == "Pawn" then return pawnSlot end end,
        __newindex = function(t, k, v)
            if k == "Pawn" then
                if v == nil and w.clearFails then error("cannot write nil") end
                if v ~= nil and v.invalid then
                    if w.invalidFails then error("cannot write an invalid object") end
                    v = nil
                end
                pawnSlot = v
                w.pawnWrites = (w.pawnWrites or 0) + 1
            else rawset(t, k, v) end
        end,
    })
    w.hostPc = hostPc
    w.hostPawn = function() return pawnSlot end
    w.player = newObj("Player_C /Game/Map.Map:PersistentLevel.Player_C_1", { ["/Script/Mist.MistPlayer"] = true })
    w.byPath["/Game/Map.Map:PersistentLevel.Player_C_1"] = w.player
    w.walls = {}
    w.gs = { GetPlayerController = function(_, ctx, index) assert(index == 0); return hostPc end }
    return w
end
local function wall(w, name, points, sites, opts)
    opts = opts or {}
    local fullName = "WallActor_C /Game/Map.Map:PersistentLevel." .. name
    local a = newObj(fullName, { ["/Script/Mist.MistWallBuildingActor"] = not opts.road })
    a.EditVersion = 1
    a.points = points
    a.Points = { GetArrayNum = function() return a.points end }
    a.kids = {}
    for i = 1, sites do a.kids[#a.kids + 1] = newObj("site" .. i, { ["/Script/Mist.MistPlaceable"] = true }) end
    a.Children = setmetatable({}, { __index = function(_, k)
        local arr = array(a.kids)
        return arr[k]
    end })
    a.pieces = math.max(0, points - 1)
    a.onrep = 0
    -- the game: UpdateMeshClient -> UpdateActor builds a site per piece only when the first
    -- controller's Pawn is a player character
    function a:OnRep_Points()
        self.onrep = self.onrep + 1
        if opts.onrepError then error("native failure") end
        local pc = w.gs:GetPlayerController(self, 0)
        local p = pc.Pawn
        w.pawnReads[#w.pawnReads + 1] = p
        if p and p.alive and p.classes["/Script/Mist.MistPlayer"] then
            while #self.kids < self.pieces do
                self.kids[#self.kids + 1] = newObj("site", { ["/Script/Mist.MistPlaceable"] = true })
            end
        end
    end
    w.byPath[fullName:match("^%S+%s+(.*)$")] = a
    w.walls[#w.walls + 1] = a
    return a
end

local function loadMod(w, opts)
    opts = opts or {}
    local hooks, loops = {}, {}
    local env = setmetatable({
        up = true, upT = 1, t = 10,
        LOG = logFile, SAVE_FILE = opts.saveFile ~= false and saveFile or nil,
        travelSignRemotePlayers = opts.players or {},
        log = function(line) w.logs[#w.logs + 1] = line end,
        safeFindAll = function(cls)
            if cls == "MistWallBuildingActor" then return w.walls end
            return {}
        end,
        objFullName = function(obj) return (obj and obj.name) or "None" end,
        RegisterHook = function(name, before, after) hooks[name:match(":(.+)$")] = { before, after } end,
        NotifyOnNewObject = function() end,
        StaticFindObject = function(path)
            if classes[path] then return classes[path] end
            if path == "/Script/Engine.Default__GameplayStatics" then return w.gs end
            return w.byPath[path]
        end,
        CreateInvalidObject = function() return { invalid = true } end,
        ExecuteInGameThread = function(callback) callback() end,
        executeInGameThreadSafe = function(_, callback) callback(); return true end,
        LoopAsync = function(_, callback) loops[#loops + 1] = callback end,
        -- v0.18.61: the block ends with the game-thread pump registration
        GAME_THREAD_WATCH = { pump = function() end }, LoopInGameThreadAfterFrames = function() end,
        os = setmetatable({
            getenv = function(k) if opts.env and opts.env[k] ~= nil then return opts.env[k] end return os.getenv(k) end,
            time = function(...) if opts.clock then return opts.clock() end return os.time(...) end,
        }, { __index = os }),
    }, { __index = _G })
    assert(load(source:sub(start), "spline hooks", "t", env))()
    for _, l in ipairs(loops) do l() end -- first pass installs the hooks
    return hooks, loops, env
end
local function param(value) return { get = function() return value end } end
local function ctxFor(pawn)
    return param({ GetOwner = function() return pawn end, GetOuter = function() return pawn end })
end
local function extend(hooks, w, a, accept)
    local version = param(a.EditVersion)
    local h = hooks.ServerExtendSpline
    h[1](ctxFor(w.player), param(a), version)
    if accept then
        a.points = a.points + 1
        a.pieces = a.points - 1
        a.EditVersion = a.EditVersion + 2
        a:OnRep_Points() -- the game's own update inside AddPoints (no character -> no site)
    end
    h[2](ctxFor(w.player), param(a), version)
end
local function has(logs, pat)
    for _, l in ipairs(logs) do if l:find(pat) then return l end end
    return nil
end
local function writeSave(bytes)
    local f = assert(io.open(saveFile, "wb")); f:write(bytes); f:close()
end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end

-- ---------------------------------------------------------------- checks
check("an accepted wall edit gets build sites and the host character slot is empty again", function()
    local w = newWorld()
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 1, 0)
    extend(hooks, w, a, true)
    assert(#a.kids == 1, "the new piece did not become a build site")
    assert(w.hostPawn() == nil, "the hidden host kept the player's character")
    assert(w.pawnReads[#w.pawnReads] == w.player, "the game did not see the placing player as builder")
    assert(has(w.logs, "wallfix: wall extended: .* build sites 0 %-> 1 builder=Player_C"), "rebuild not logged")
end)

check("every later segment of the same wall gets its build site too", function()
    local w = newWorld()
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 1, 0)
    for _ = 1, 4 do extend(hooks, w, a, true) end
    assert(#a.kids == 4 and w.hostPawn() == nil)
end)

check("a rejected edit (stale version) does not rerun the wall", function()
    local w = newWorld()
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 2, 1)
    local before = a.onrep
    extend(hooks, w, a, false)
    assert(a.onrep == before, "a rejected edit reran the wall update")
    -- the stale remove right after an extend is refused by the game and changes nothing either
    local h = hooks.ServerRemoveSpline
    h[1](ctxFor(w.player), param(a), param(1)); h[2](ctxFor(w.player), param(a), param(1))
    assert(a.onrep == before and w.hostPawn() == nil)
end)

check("roads are left alone", function()
    local w = newWorld()
    local hooks = loadMod(w)
    local r = wall(w, "RoadActor_C_1", 1, 0, { road = true })
    extend(hooks, w, r, true)
    assert(r.onrep == 1 and (w.pawnWrites or 0) == 0, "a road was rerun or the host character slot was touched")
end)

check("switched off by environment or by the marker file", function()
    local w = newWorld()
    local hooks = loadMod(w, { env = { HEARTH_WALL_BUILDER = "0" } })
    local a = wall(w, "WallActor_C_1", 1, 0)
    extend(hooks, w, a, true)
    assert(#a.kids == 0 and (w.pawnWrites or 0) == 0)
    local w2 = newWorld()
    local hooks2 = loadMod(w2)
    local f = assert(io.open(offMarker, "w")); f:write("off"); f:close()
    local b = wall(w2, "WallActor_C_1", 1, 0)
    extend(hooks2, w2, b, true)
    os.remove(offMarker)
    assert(#b.kids == 0 and (w2.pawnWrites or 0) == 0, "the marker file did not switch the fix off")
    assert(has(w2.logs, "switched off by"), "the off switch was not logged")
end)

check("a native failure inside the update still empties the host character slot", function()
    local w = newWorld()
    local hooks = loadMod(w)
    local b = wall(w, "WallActor_C_1", 2, 0, { onrepError = true })
    hooks.ServerExtendSpline[1](ctxFor(w.player), param(b), param(1))
    b.EditVersion = 3
    hooks.ServerExtendSpline[2](ctxFor(w.player), param(b), param(1))
    assert(b.onrep == 1, "the wall update did not run")
    assert(w.hostPawn() == nil, "the host kept the character after a failed update")
    assert(has(w.logs, "result=failed"), "failure not logged")
end)

check("no swap at all when an empty character slot cannot be written; the fix turns itself off", function()
    local w = newWorld({ clearFails = true, invalidFails = true })
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 1, 0)
    extend(hooks, w, a, true)
    extend(hooks, w, a, true)
    assert(w.hostPawn() == nil and #a.kids == 0, "swapped although the slot could not be emptied")
    assert(has(w.logs, "cannot write an empty Pawn"), "self switch-off not logged")
end)

check("the empty slot falls back to an invalid object when nil cannot be written", function()
    local w = newWorld({ clearFails = true })
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 1, 0)
    extend(hooks, w, a, true)
    assert(w.hostPawn() == nil and #a.kids == 1, "fallback clear path did not work")
end)

check("a host that already has a character is not touched", function()
    local hostChar = newObj("Player_C host", { ["/Script/Mist.MistPlayer"] = true })
    local w = newWorld({ hostPawn = hostChar })
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 1, 0)
    extend(hooks, w, a, true)
    assert(w.hostPawn() == hostChar and (w.pawnWrites or 0) == 0, "the host's own character was replaced")
end)

check("a placer that is not a player character is never used as builder", function()
    local w = newWorld()
    local hooks = loadMod(w)
    local a = wall(w, "WallActor_C_1", 1, 0)
    local npc = newObj("Npc", {})
    hooks.ServerExtendSpline[1](ctxFor(npc), param(a), param(1))
    a.points, a.pieces, a.EditVersion = 2, 1, 3
    hooks.ServerExtendSpline[2](ctxFor(npc), param(a), param(1))
    assert(#a.kids == 0 and (w.pawnWrites or 0) == 0)
end)

check("saved walls without build sites are healed after a save copy; healthy walls untouched", function()
    writeSave(string.rep("S", 4096))
    os.remove(saveFile .. ".wallheal.bak")
    local w = newWorld()
    local stuck = wall(w, "WallActor_C_7", 3, 0)
    local healthy = wall(w, "WallActor_C_8", 3, 2)
    local lone = wall(w, "WallActor_C_9", 1, 0)
    local _, loops = loadMod(w, { players = { "Player_C /Game/Map.Map:PersistentLevel.Player_C_1" } })
    assert(readFile(saveFile .. ".wallheal.bak") == string.rep("S", 4096), "no save copy before healing")
    assert(readFile(saveFile .. ".wallheal.bak.tmp") == nil, "temp copy left behind")
    assert(#stuck.kids == 2, "the stuck saved wall was not healed")
    assert(healthy.onrep == 0, "a wall that has build sites was rerun")
    assert(lone.onrep == 0, "a single post was rerun")
    assert(w.hostPawn() == nil)
    assert(has(w.logs, "heal saved wall .*WallActor_C_7 points=3 build sites 0 %-> 2"), "heal not logged per wall")
    assert(has(w.logs, "scan: 3 walls, 1 without build sites"), "scan summary missing")
    -- once per session: a second pass does nothing
    local runs = stuck.onrep
    for _, l in ipairs(loops) do l() end
    assert(stuck.onrep == runs, "healed twice")
end)

check("no save copy, no healing of saved walls", function()
    local w = newWorld()
    local stuck = wall(w, "WallActor_C_7", 3, 0)
    local _, loops = loadMod(w, { saveFile = false, players = { "Player_C /Game/Map.Map:PersistentLevel.Player_C_1" } })
    assert(stuck.onrep == 0 and #stuck.kids == 0, "healed without a save copy")
    assert(has(w.logs, "NOT written"), "the missing copy was not logged")
end)

check("nobody online: nothing is scanned or healed", function()
    writeSave("x")
    local w = newWorld()
    local stuck = wall(w, "WallActor_C_7", 3, 0)
    local _, loops = loadMod(w, { players = {} })
    for _, l in ipairs(loops) do l() end
    assert(stuck.onrep == 0 and not has(w.logs, "scan:"))
end)

check("a piece the game re-solves later without a build site is rebuilt on the recheck", function()
    local now = 1000000
    local w = newWorld()
    local a = wall(w, "WallActor_C_1", 1, 0)
    local hooks, loops = loadMod(w, { clock = function() return now end,
        players = { "Player_C /Game/Map.Map:PersistentLevel.Player_C_1" } })
    for _, l in ipairs(loops) do l() end -- first sweep: nothing stuck yet
    extend(hooks, w, a, true)
    assert(#a.kids == 1)
    a.kids = {} -- the game's 15 s timer replaced the piece and nobody built it
    now = now + 10
    for _, l in ipairs(loops) do l() end
    assert(#a.kids == 0, "rechecked before the game's own timer")
    now = now + 15
    for _, l in ipairs(loops) do l() end
    assert(#a.kids == 1 and w.hostPawn() == nil, "the re-solved piece was not rebuilt")
    assert(has(w.logs, "recheck after the game's re%-solve"), "recheck not logged")
end)

check("a wall the player takes down is logged and never rechecked as a lost one (v0.18.61)", function()
    local now = 2000000
    local w = newWorld()
    local a = wall(w, "WallActor_C_1", 1, 0)
    local hooks, loops = loadMod(w, { clock = function() return now end,
        players = { "Player_C /Game/Map.Map:PersistentLevel.Player_C_1" } })
    for _, l in ipairs(loops) do l() end
    extend(hooks, w, a, true)
    assert(#a.kids == 1)
    -- the game's Disassemble on a 2-point wall destroys the actor; it stays findable until GC
    hooks.ServerDisassemble[1](ctxFor(w.player), param(a), param(0))
    a.kids = {}
    assert(has(w.logs, "wall taken down by the player WallActor_C_1 piece=0 points=2"), "take-down not logged")
    local runs = a.onrep
    now = now + 30
    for _, l in ipairs(loops) do l() end
    assert(a.onrep == runs and not has(w.logs, "recheck after the game's re%-solve"), "a removed wall was rechecked")
end)

os.remove(saveFile); os.remove(saveFile .. ".wallheal.bak"); os.remove(logFile); os.remove(tmpdir)
print("Passed " .. passed .. " wall build-site checks (mocked engine; retail validation still required).")
