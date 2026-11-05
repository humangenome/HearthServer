-- bw_ident v0.1.0: a returning player's character follows their Steam account on the Hearth headless Bellwright host.
--
-- Bellwright keys a character on the joining computer's offline id, so a new or renamed computer started a new
-- character. HearthIdentity.dll hooks the game's login check: a join that carries a HearthServer token
-- for its Steam ID (HearthServer checked the player's Steam ticket before signing it) is pointed at the first computer
-- id HearthServer recorded for that Steam ID. No token or a bad one: the join is unchanged.
-- v0.2.0: the same check refuses a join without the server's password when the owner set one (HearthServer writes
-- HearthServer\data\join-gate.txt; the app sends the player's password with the join). A refused join gets the
-- game's own refusal and never gets a character record.
--
-- This script only loads the DLL and calls it on the game thread: the first call installs the hook (long before the
-- world opens), later calls let it write a status line. All of the work is native and build-locked; on a Bellwright
-- build it does not know, it installs nothing. Isolated UE4SS mod (own lua_State): a failure here cannot take
-- bw_host down.
local MOD_VERSION = "v0.2.0"
local DLL = ".\\ue4ss\\Mods\\bw_ident\\HearthIdentity.dll"

local LOG = os.getenv("HEARTH_HOST_LOG") or os.getenv("BW_HOST_LOG")
if LOG and #LOG > 0 then LOG = LOG:gsub("bw_host%.log$", "bw_identity.log") end
if not LOG or #LOG == 0 or LOG:match("bw_host") then
    LOG = (os.getenv("LOCALAPPDATA") or "C:\\Temp") .. "\\bw_identity.log"
end

local function log(m)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("%H:%M:%S ") .. "[bw_ident] " .. tostring(m) .. "\r\n"); f:close() end
    end)
end
log("mod loaded " .. MOD_VERSION)

local service = nil
local gaveUp = false

local function loadNative()
    if service then return true end
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        log("native unavailable: package.loadlib missing"); return false
    end
    local ok, fn = pcall(package.loadlib, DLL, "HearthIdentity_Service")
    if ok and type(fn) == "function" then service = fn; return true end
    log("native load failed path=" .. DLL .. " err=" .. tostring(fn))
    return false
end

-- Runs from one game-thread loop (LoopInGameThreadWithDelay, every 2 s), registered as the last UE4SS call of this
-- file; no background code (tests/host-thread-safety.test.lua).
local function serviceOnGameThread()
    if gaveUp then return end
    if not loadNative() then gaveUp = true; return end
    local cok, cerr = pcall(service)
    if not cok then log("native call failed: " .. tostring(cerr)) end
end
local loopOk, loopErr = pcall(LoopInGameThreadWithDelay, 2000, serviceOnGameThread)
log("game-thread loop registered=" .. tostring(loopOk) .. (loopOk and "" or (" err=" .. tostring(loopErr))))
