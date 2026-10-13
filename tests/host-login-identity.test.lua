-- Run from the repository root: lua5.4 tests/host-login-identity.test.lua
-- Optional first argument selects an older host mod for regression replay.
-- Loads the whole host mod against a stub UE4SS and replays joins over blind
-- connections (no readable remote address or request URL, as on the fleet), so
-- every identity comes from HearthServer's login-identities rows. This checks the
-- mod's identity bookkeeping, not a retail client.
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
local stubOs = setmetatable({
    time = function(t) if t then return os.time(t) end return NOW end,
    getenv = function(k)
        if k == "HEARTH_HOST_LOG" then return LOG end
        if k == "HEARTH_SERVER_DIR" then return SERVER_DIR end
        return nil
    end,
}, { __index = os })

local drivers = {}
local noop = function() return nil end
local env = setmetatable({
    os = stubOs,
    LoopAsync = noop, ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = noop, RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback) callback() end,
    FindAllOf = function(name) if name == "IpNetDriver" then return drivers end return {} end,
    FindFirstOf = noop, StaticFindObject = noop, print = noop,
}, { __index = function(_, k) local v = _G[k]; if v ~= nil then return v end return noop end })

local exports = "\nreturn { ready = remoteIdentityReady, seed = seedJoinerIdentity,"
    .. " stableSeedByPc = stableSeedByPc, stableIdByPc = stableIdByPc }\n"
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
local conns = { GetArrayNum = function(self) return #self end }
drivers[1] = uobj(9000, "IpNetDriver /Engine/Transient.IpNetDriver_0", { ClientConnections = conns })

-- A player on a blind connection: controller + player state + conn, listed on the driver.
local function join(pcAddr, pcSerial, connAddr, connSerial, name)
    local ps = uobj(pcAddr + 1, "OasisPlayerState_C " .. LEVEL .. "OasisPlayerState_C_" .. pcSerial,
        { GetPlayerName = function() return name end })
    local pc = uobj(pcAddr, "OasisPlayerController_C " .. LEVEL .. "OasisPlayerController_C_" .. pcSerial,
        { PlayerState = ps, IsLocalPlayerController = function() return false end })
    local conn = uobj(connAddr, "IpConnection /Engine/Transient.IpConnection_" .. connSerial, { OwningActor = pc })
    conns[#conns + 1] = conn
    return { pc = pc, conn = conn }
end
local function leave(p)
    for i = #conns, 1, -1 do if conns[i] == p.conn then table.remove(conns, i) end end
end
-- HearthServer's file: ts(ms), address, uid, seed, display, login name, admin ticket.
local function rows(list)
    local f = assert(io.open(TSV, "w"))
    for _, r in ipairs(list) do
        f:write(table.concat({ tostring(r.ts * 1000), r.addr or "", "steam_" .. r.id, "steam_" .. r.id,
            r.display or "Player", "", "" }, "\t"), "\n")
    end
    f:close()
end
local function tick(seconds) NOW = NOW + (seconds or 1) end
-- One service pass for a controller, the way serviceJoiners drives it.
local function pass(p)
    local ready = mod.ready(p.pc, p.conn)
    if ready then mod.seed(p.pc, "test") end
    return ready
end
local function seedOf(p) return mod.stableSeedByPc[p.pc.__addr] end

local passed = 0
local function check(name, body)
    for i = #conns, 1, -1 do conns[i] = nil end
    body()
    passed = passed + 1
    print("ok - " .. name)
end

check("a player who joins 46 minutes after a friend gets their own identity, and the friend keeps theirs", function()
    rows({ { ts = NOW, id = "76561198000000001", addr = "10.0.0.1%3A5000", display = "Ann" } })
    local ann = join(1000, 1, 5000, 0, "Ann")
    assert(pass(ann), "Ann identified at login")
    assert(seedOf(ann) == "steam_76561198000000001")
    tick(46 * 60) -- HearthServer has dropped Ann's row (45 min)
    rows({ { ts = NOW, id = "76561198000000002", addr = "10.0.0.2%3A5001", display = "Ben" } })
    local ben = join(1100, 2, 5100, 1, "Ben")
    assert(pass(ann), "Ann still serviced")
    assert(seedOf(ann) == "steam_76561198000000001", "Ann became " .. tostring(seedOf(ann)))
    assert(pass(ben), "Ben got no identity (the old player took his row)")
    assert(seedOf(ben) == "steam_76561198000000002", "Ben is " .. tostring(seedOf(ben)))
    tick(2)
    assert(pass(ann) and pass(ben))
    assert(seedOf(ann) == "steam_76561198000000001" and seedOf(ben) == "steam_76561198000000002")
    leave(ann); leave(ben)
end)

check("two friends joining together keep their own rows when HearthServer rewrites one", function()
    tick(600)
    local t0 = NOW
    rows({ { ts = t0, id = "76561198000000011", display = "Player" },
           { ts = t0 + 1, id = "76561198000000012", display = "Player" } })
    tick(1)
    local cy = join(2000, 3, 6000, 2, "Cy")
    assert(pass(cy))
    tick(3) -- the display arrives and HearthServer rewrites Cy's row with a new time
    rows({ { ts = t0 + 1, id = "76561198000000012", display = "Player" },
           { ts = t0 + 4, id = "76561198000000011", display = "Cy" } })
    tick(1)
    assert(pass(cy))
    local di = join(2100, 4, 6100, 3, "Di")
    assert(pass(di), "Di got no identity")
    assert(seedOf(cy) == "steam_76561198000000011", "Cy is " .. tostring(seedOf(cy)))
    assert(seedOf(di) == "steam_76561198000000012", "Di is " .. tostring(seedOf(di)))
    leave(cy); leave(di)
end)

check("a new connection at a departed connection's address claims its own row", function()
    tick(600)
    rows({ { ts = NOW, id = "76561198000000021", display = "Ed" } })
    local ed = join(3000, 5, 7000, 4, "Ed")
    assert(pass(ed) and seedOf(ed) == "steam_76561198000000021")
    leave(ed)
    tick(5)
    rows({ { ts = NOW, id = "76561198000000022", display = "Flo" } })
    local flo = join(3100, 6, 7000, 9, "Flo") -- same conn address, new IpConnection serial
    assert(pass(flo), "Flo got no identity")
    assert(seedOf(flo) == "steam_76561198000000022", "Flo is " .. tostring(seedOf(flo)))
    leave(flo)
end)

check("a new controller at a departed controller's address does not inherit its identity", function()
    tick(600)
    rows({ { ts = NOW, id = "76561198000000031", display = "Gus" } })
    local gus = join(4000, 7, 8000, 10, "Gus")
    assert(pass(gus) and seedOf(gus) == "steam_76561198000000031")
    leave(gus)
    tick(5)
    rows({ { ts = NOW, id = "76561198000000032", display = "Hal" } })
    local hal = join(4000, 11, 8100, 11, "Hal") -- same controller address, new serial
    assert(pass(hal))
    assert(seedOf(hal) == "steam_76561198000000032", "Hal is " .. tostring(seedOf(hal)))
    leave(hal)
end)

check("a player whose row has expired keeps their Steam identity with nobody joining", function()
    tick(600)
    rows({ { ts = NOW, id = "76561198000000041", display = "Ivy" } })
    local ivy = join(5000, 12, 9000, 12, "Ivy")
    assert(pass(ivy))
    tick(46 * 60)
    rows({})
    assert(pass(ivy), "Ivy no longer serviced")
    assert(seedOf(ivy) == "steam_76561198000000041", "Ivy is " .. tostring(seedOf(ivy)))
    leave(ivy)
end)

os.remove(TSV)
os.remove(LOG)
os.execute("rm -rf '" .. dir .. "'")
print(passed .. " checks passed")
