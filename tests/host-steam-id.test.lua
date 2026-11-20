-- Run from the repository root: lua5.4 tests/host-steam-id.test.lua
-- Optional first argument selects an older host mod for regression replay.
-- Loads the whole host mod against a stub UE4SS and checks its one SteamID64 rule:
-- 17 ASCII digits, account 1 to 2^32-1 (76561197960265729 to 76561202255233023).
-- Steam's newer accounts start 7656120 instead of 7656119; they must be able to be
-- configured admins and to get a Steam-backed identity.
local path = arg[1] or "dist/ue4ss-server/Mods/bw_host/Scripts/main.lua"
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/Logs'"))

local ENV = {
    HEARTH_HOST_LOG = dir .. "/Logs/bw_host.log",
    HEARTH_SERVER_DIR = dir .. "/HearthServer",
    -- a mix of good and bad admin entries, separated the ways an owner might type them
    HEARTH_ADMIN_STEAM_IDS = "76561197960265729, 76561198000000001,76561200000000001\t76561202255233023"
        .. ",76561197960265728,76561202255233024,7656119800000000,765611980000000011,7656119800000000a",
}
local stubOs = setmetatable({
    time = function(t) if t then return os.time(t) end return 1791600000 end,
    getenv = function(k) return ENV[k] end,
}, { __index = os })

local noop = function() return nil end
local env = setmetatable({
    LoopInGameThreadAfterFrames = noop,
    os = stubOs,
    LoopAsync = noop, ExecuteWithDelay = noop, ExecuteAsync = noop, RegisterHook = noop,
    NotifyOnNewObject = noop, RegisterKeyBind = noop, RegisterConsoleCommandHandler = noop,
    ExecuteInGameThread = function(callback) callback() end,
    FindAllOf = function() return {} end,
    FindFirstOf = noop, StaticFindObject = noop, print = noop,
}, { __index = function(_, k)
    local v = _G[k]; if v ~= nil then return v end
    -- UE4SS's API is capitalised; a lowercase miss is a helper used above its definition
    if type(k) == "string" and k:match("^[a-z]") and k ~= "hostUp" then error("undefined global '" .. k .. "'", 2) end
    return noop
end })

local mod = assert(load(source .. "\nreturn { admin = ADMIN_AUTH }\n", "main.lua", "t", env))()
local admin = mod.admin

local passed, failed = 0, 0
local function check(name, ok)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end

local accepted = { "76561197960265729", "76561198000000001", "76561200000000001", "76561202255233023" }
local refused = {
    "76561197960265728", "76561202255233024", "7656119800000000", "765611980000000011", "7656119800000000a",
    " 76561198000000001", "76561198000000001 ", "76561198000000001\n", "7656119800000000\n",
    "\239\188\151\239\188\150\239\188\149\239\188\150\239\188\145", -- fullwidth digits (UTF-8)
    "", false, 76561198000000001,
}

for _, id in ipairs(accepted) do
    check("rule accepts " .. id, admin.isSteamId64(id) == true)
    check("steam_ form gives the id for " .. id, admin.steam64FromIdentity("steam_" .. id) == id)
    check("bare form gives the id for " .. id, admin.steam64FromIdentity(id) == id)
    check("configured admin " .. id, admin.configured[id] == true)
end
check("rule refuses nil", admin.isSteamId64(nil) == false)
check("no Steam id from nil", admin.steam64FromIdentity(nil) == nil)
for _, id in ipairs(refused) do
    local label = string.format("%q", tostring(id))
    check("rule refuses " .. label, admin.isSteamId64(id) == false)
    if type(id) == "string" then
        check("no Steam id from steam_" .. label, admin.steam64FromIdentity("steam_" .. id) == nil
            -- the identity reader trims, so a padded good id is still that id
            or admin.steam64FromIdentity("steam_" .. id) == id:match("^%s*(.-)%s*$"))
        check("not configured " .. label, admin.configured[id] == nil)
    end
end
check("exactly the four good admin entries are configured", admin.count == #accepted)
-- a computer-name identity (Bellwright's own Null login) is never read as a Steam account
check("computer name is not a Steam id", admin.steam64FromIdentity("Main-PC-B709A2C846E162BC6955D593EF35BF32") == nil)

if dir:match("^/tmp/lua_%w+$") then os.execute("rm -rf '" .. dir .. "'") end
print(passed .. " checks passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
