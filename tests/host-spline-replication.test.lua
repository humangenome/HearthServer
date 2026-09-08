-- Run from the repository root: lua5.4 tests/host-spline-replication.test.lua
-- Optional first argument selects an older host mod for regression replay.
-- Executes the real RPC hooks with a dormant-replication model. This verifies
-- callback ordering and safety, not a retail client's rendered wall placement.
local file = assert(io.open(arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua", "r"))
local source = file:read("*a")
file:close()
local start = assert(source:find("do\nlocal sw =", 1, true), "spline hook block not found")
local hooks, logs = {}, {}
local env = setmetatable({
    up = true, upT = 1, t = 10,
    log = function(line) logs[#logs + 1] = line end,
    safeFindAll = function() return {} end,
    objFullName = function(obj) return obj and obj.name or "nil" end,
    RegisterHook = function(name, before, after)
        hooks[name:match(":(.+)$")] = { before, after }
    end,
    NotifyOnNewObject = function() end,
    ExecuteInGameThread = function(callback) callback() end,
    LoopAsync = function(_, callback) callback() end,
}, { __index = _G })
assert(load(source:sub(start), "spline hooks", "t", env))()
local count = 0
for _ in pairs(hooks) do count = count + 1 end
assert(count == 6, "all six spline RPCs must be installed")

local function param(value)
    return { get = function() return value end }
end
local ctx = param({ GetOuter = function() return { name = "remote player" } end })
local function actor(name)
    local a = {
        name = name or "wall", alive = true, dormant = true, EditVersion = 1,
        pointCount = 1, clientPoints = 1, clientVersion = 1,
        NetDormancy = 2, events = {}, flushes = 0, updates = 0,
    }
    a.Points = { GetArrayNum = function() return a.pointCount end }
    function a:IsValid() return self.alive end
    function a:FlushNetDormancy()
        assert(self.alive, "accessed a destroyed spline")
        self.events[#self.events + 1] = "flush"
        self.flushes = self.flushes + 1
        if self.dormant then
            -- Epic's documented wake behavior: current properties become the
            -- comparison baseline. A post-mutation wake can miss the change.
            self.baseline = { self.pointCount, self.EditVersion }
            self.dormant = false
        end
    end
    function a:ForceNetUpdate()
        assert(self.alive, "accessed a destroyed spline")
        self.events[#self.events + 1] = "force"
        self.updates = self.updates + 1
        if self.dormant then self:FlushNetDormancy() end
        self.pending = true
    end
    function a:edit(points)
        self.events[#self.events + 1] = "edit"
        self.pointCount = points
        self.EditVersion = self.EditVersion + 1
    end
    function a:replicate()
        if self.pending and self.baseline and
            (self.pointCount ~= self.baseline[1] or self.EditVersion ~= self.baseline[2]) then
            self.clientPoints, self.clientVersion = self.pointCount, self.EditVersion
        end
        self.pending, self.dormant = false, true
    end
    return a
end
local function rpc(name, args, native)
    local hook = assert(hooks[name], name)
    hook[1](ctx, table.unpack(args))
    native()
    hook[2](ctx, table.unpack(args))
end
local passed = 0
local function check(name, body)
    body()
    passed = passed + 1
    print("ok " .. passed .. " - " .. name)
end

check("accepted extensions reach a remote copy across repeated dormancy", function()
    local a = actor()
    for expected = 2, 4 do
        local version = param(a.clientVersion)
        rpc("ServerExtendSpline", { param(a), version }, function()
            assert(version:get() == a.EditVersion, "client version did not catch up")
            a:edit(expected)
        end)
        a:replicate()
        assert(a.clientPoints == expected, "accepted extension was lost during dormancy wake")
        assert(a.clientVersion == a.EditVersion, "edit version was not replicated")
    end
end)

check("closing and removing segments publish their native changes", function()
    for _, name in ipairs({ "ServerCloseSpline", "ServerRemoveSplineSegment" }) do
        local a = actor()
        rpc(name, { param(a), param(1) }, function() a:edit(2) end)
        a:replicate()
        assert(a.clientPoints == 2 and a.clientVersion == 2, name .. " failed to replicate")
    end
end)

check("combining splines wakes both actors in the native parameter positions", function()
    local a, b = actor("first"), actor("second")
    rpc("ServerCombineSplines", { param(a), param(1), param(false), param(b), param(1), param(true) }, function()
        a:edit(3)
        b:edit(0)
    end)
    a:replicate()
    b:replicate()
    assert(a.clientPoints == 3 and b.clientPoints == 0, "both spline changes must replicate")
end)

check("stale client versions remain rejected by the game", function()
    local a = actor()
    a.EditVersion, a.clientVersion = 2, 1
    local version, accepted = param(1), false
    rpc("ServerExtendSpline", { param(a), version }, function()
        if version:get() == a.EditVersion then accepted = true; a:edit(2) end
    end)
    assert(not accepted and a.pointCount == 1 and version:get() == 1, "native version gate was bypassed")
end)

check("native crafting rejection does not create a wall or rewrite points", function()
    local a = actor()
    rpc("ServerExtendSpline", { param(a), param(1) }, function() end)
    a:replicate()
    assert(a.pointCount == 1 and a.EditVersion == 1 and a.clientPoints == 1)
end)

check("successful removal never updates a destroyed actor", function()
    local a = actor()
    rpc("ServerRemoveSpline", { param(a), param(1) }, function() a.alive = false end)
    assert(a.flushes == 1 and a.updates == 0, "destroyed spline received a post-edit call")
end)

check("combine can destroy either actor without losing the survivor update", function()
    for destroyed = 1, 2 do
        local a, b = actor("first"), actor("second")
        local pair = { a, b }
        local survivor = pair[3 - destroyed]
        rpc("ServerCombineSplines", { param(a), param(1), param(false), param(b), param(1) }, function()
            pair[destroyed].alive = false
            survivor:edit(3)
        end)
        survivor:replicate()
        assert(survivor.clientPoints == 3 and pair[destroyed].updates == 0)
    end
end)

check("invalid actors and reflection errors do not escape into the game", function()
    rpc("ServerExtendSpline", { param(nil), param(1) }, function() end)
    local a = actor()
    a.FlushNetDormancy = function() error("reflection failure") end
    a.ForceNetUpdate = function() error("reflection failure") end
    local ran = false
    rpc("ServerExtendSpline", { param(a), param(1) }, function() ran = true end)
    assert(ran, "replication diagnostic failure prevented the native call")
end)

check("bounded diagnostics do not stop replication after the log limit", function()
    local a = actor()
    for expected = 2, 150 do
        rpc("ServerExtendSpline", { param(a), param(a.clientVersion) }, function() a:edit(expected) end)
        a:replicate()
        assert(a.clientPoints == expected, "replication stopped when logging filled")
    end
end)
print("Passed " .. passed .. " spline hook behavior checks (mocked engine; retail validation still required).")
