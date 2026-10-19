-- bw_seat4 v0.1.0: a world-data seat for the fourth player on the Hearth headless Bellwright host.
--
-- Bellwright sends world data (settlements, villagers, orders, quests, storage) to at most
-- three joining players; the game is built as one listening host plus three guests, and the
-- headless host owns the host seat.  A fourth guest gets into the world but receives no world
-- data, so their loading screen never clears.  HearthFourthSeat.dll serves that player beside
-- the game's three seats, with the game's own batches and the game's own acknowledgements.
--
-- This script only loads the DLL and calls it on the game thread: the first call installs it
-- (long before the world opens), later calls let it write a status line.  All of the work is
-- native and build-locked; on a Bellwright build it does not know, it installs nothing.
--
-- Isolated UE4SS mod (own lua_State): a failure here cannot take bw_host down.
local MOD_VERSION = "v0.1.2"
local DLL = ".\\ue4ss\\Mods\\bw_seat4\\HearthFourthSeat.dll"
local STATUS = ".\\ue4ss\\Mods\\bw_seat4\\fourth-seat-status.txt"

local LOG = os.getenv("HEARTH_HOST_LOG") or os.getenv("BW_HOST_LOG")
if LOG and #LOG > 0 then LOG = LOG:gsub("bw_host%.log$", "bw_seat4.log") end
if not LOG or #LOG == 0 or LOG:match("bw_host") then
    LOG = (os.getenv("LOCALAPPDATA") or "C:\\Temp") .. "\\bw_seat4.log"
end

local function log(m)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(os.date("%H:%M:%S ") .. "[bw_seat4] " .. tostring(m) .. "\r\n"); f:close() end
    end)
end
log("mod loaded " .. MOD_VERSION)

local service = nil
local reported = false
local gaveUp = false

local function loadNative()
    if service then return true end
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        log("native unavailable: package.loadlib missing"); return false
    end
    local ok, fn = pcall(package.loadlib, DLL, "HearthFourthSeat_Service")
    if ok and type(fn) == "function" then service = fn; return true end
    log("native load failed path=" .. DLL .. " err=" .. tostring(fn))
    return false
end

local function readStatus()
    local f = io.open(STATUS, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return (tostring(s):gsub("[\r\n]+", " "))
end

-- v0.1.2 (2026-10-18): the call runs from one game-thread loop (LoopInGameThreadWithDelay, every 2 s),
-- registered as the last UE4SS call of this file. Until v0.1.1 a background loop (LoopAsync) queued it
-- with ExecuteInGameThread, and in UE4SS b50986bd that call writes to the Lua stack the game thread is
-- running on with nothing locking the two: it could leave UE4SS's game-thread queue dead for the rest
-- of the session ("Ref was not function") or crash the game. No background code here any more
-- (tests/host-thread-safety.test.lua).
local function serviceOnGameThread()
    if gaveUp then return end
    if not loadNative() then gaveUp = true; return end
    local cok, cerr = pcall(service)
    if not cok then log("native call failed: " .. tostring(cerr)) end
    if not reported then
        reported = true
        log("native status " .. tostring(readStatus() or "missing"))
    end
end
local loopOk, loopErr = pcall(LoopInGameThreadWithDelay, 2000, serviceOnGameThread)
log("game-thread loop registered=" .. tostring(loopOk) .. (loopOk and "" or (" err=" .. tostring(loopErr))))
