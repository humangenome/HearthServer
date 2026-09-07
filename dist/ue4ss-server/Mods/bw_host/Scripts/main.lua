-- bw_host v0.18.50: Bellwright (UE5.7.4 "Mist") headless host mod for Hearth.
--   v0.18.50: stop holding UObject handles across ticks. Three host crashes
--              (one server: 2026-08-29, 2026-09-05, 2026-09-06) symbolized against
--              the pinned UE4SS b50986bd PDB: two access violations inside the
--              UE4SS call thunk / object wrapper while a queued game-thread
--              callback called a UFunction with a component, provider, icon class
--              or pawn handle the Travel Sign code had kept from an earlier tick,
--              and one process abort from a Lua error escaping a LoopAsync body.
--              Travel Sign memory now stores object PATHS and resolves each one
--              through StaticFindObject on the game thread at the moment of use,
--              remote pawns are resolved the same way, every LoopAsync body runs
--              under pcall, and a live-world change (the Halmare voyage and the
--              trip back are ServerTravel) clears the Travel Sign memory and
--              re-runs the startup sweep so the map is not empty until a restart.
--   v0.18.49: apply host-managed gameplay settings through a build-locked
--              native server path. Bellwright's own SaveChanges deliberately
--              skips persistence on NM_Client, so a remote player's host flag
--              can never save these values. The native helper runs only on the
--              game thread, verifies the exact retail executable, invokes the
--              authoritative UMistGameSettingsData setters, mirrors the game's
--              persistence-dirty calls, and writes exact readback status. Keep
--              polling the immutable config revision so Apply works live and
--              startup readiness can fail closed on missing/mismatched settings.
--   v0.18.48: bound the late-spawn Travel Sign sweep to startup instead of
--              walking every map-icon provider for the lifetime of the host.
--              Remember non-travel providers after their owner resolves, rely
--              on the existing object hooks for later arrivals, and protect
--              every queued game-thread callback with a Lua-level pcall so an
--              ordinary callback error cannot enter UE4SS's unsafe traceback
--              path and terminate the host process.
--   v0.18.47: permit only the MapFog actor tick after all four build-locked
--              null-RHI patches verify. Keep every component tick disabled. The
--              missing fourth patch skips the exact UMapRevealerComponent virtual
--              call whose null Canvas caused both v0.1.77 crashes at 62 seconds.
--   v0.18.46: keep looking for Travel Signs instead of trusting one boot-time
--              sweep. On a loaded save the Fast Travel components can spawn after
--              that sweep, which returned components=0 providers=820 on a live
--              server; the scan was one-shot, so nothing ever looked again and
--              only a sign that happened to arrive through the runtime hook was
--              ever repaired. Rescan on an interval, clear give-up markers so a
--              component that failed only because its owner was not ready yet is
--              retried, and always sweep the world on a player sync pass instead
--              of only when nothing has been remembered — that guard meant one
--              known sign permanently disabled the search for the rest.
--   v0.18.45: deliver the granted admin flag to a client whose pawn went dormant,
--              and stop trusting a silent write. ForceNetUpdate only flushes net
--              dormancy when it can resolve a NetDriver for the actor, so a
--              DORM_Initial pawn keeps its opening bunch and never sends the
--              property again. Call FlushNetDormancy explicitly, republish the
--              write across the first few service ticks, and log the read-back
--              value plus the dormancy state so a locked client can be told apart
--              from a failed write. No change to who may be granted authority.
--   v0.18.44: replay completed Travel Signs through Bellwright's reflected
--              ServerRepairTravelComponent RPC for each ready remote player.
--              Keep the existing bounded road/icon refresh and MapFog guard;
--              this remains scoped to completed FastTravelSign_C actors.
--   v0.18.43: publish the authenticated bIsHostPlayer write to the owning client.
--              bIsHostPlayer is a replicated native property and this build links
--              Unreal's push-model replication, so the direct write never left server
--              memory and the gameplay-settings UI stayed locked. Mark the property
--              dirty through the reflected UNetPushModelHelpers and force a net update
--              on the owner, and disable push model pre-host when an admin is
--              configured so the listen server's rep layouts never skip the compare.
--              No change to who may be granted authority.
--   v0.18.42: consume the authenticated admin ticket from HearthServer's
--              validated login cache when UE4SS cannot reflect RequestURL.
--   v0.18.41: grant Bellwright's replicated bIsHostPlayer authority only after
--              a one-use HearthServer ticket proves the RCON/admin password and
--              binds the configured Steam64 identity to the connection source.
--   v0.18.40: promote a newly completed Travel Sign to the bounded player-sync
--              path when remote players are already connected. This refreshes
--              that sign's road graph and false/true discovery state without
--              enabling MapFog or replaying unrelated map icons.
--   v0.18.39: replay completed Travel Sign discovery after a remote player's
--              map-icon manager and possessed pawn are ready. Bellwright ignores
--              a repeated true-only discovery request once the provider is
--              already marked, so use its built-in false/true transition in
--              three bounded post-join passes and refresh the sign road graph.
--   v0.18.38: pair Travel Sign and map-icon-provider subobjects through their
--              shared actor owner. Provider construction can lag the fast-travel
--              component by more than the bounded retry window; the provider
--              object hook now re-arms that exact sign when it becomes ready.
--   v0.18.37: keep MapFog fully disabled under null-RHI and repair only completed
--              Travel Sign discovery through Bellwright's built-in
--              SetMapIconDiscovered path. Full MapFog ticking still crashes after
--              the known render paths are patched.
--   v0.18.35: invoke the already-validated operator save component directly
--              after the game-thread handoff. Revalidating the reflected object
--              inside the callback can stall the Unreal game thread.
--   v0.18.34: make operator save-component resolution fail-safe. Validate
--   reflected objects inside protected calls, fall back to a bounded class
--   scan, and surface service-loop errors instead of silently swallowing the
--   request while its port-scoped marker remains pending.
--   v0.18.33: resolve the native cheating component from the established
--   service loop before queueing the game-thread save call. A fresh full-object
--   lookup inside the callback can abort the callback before it logs or clears
--   the marker; the queued callback now only validates and invokes the cached
--   component, with every callback error logged and retried safely.
--   v0.18.32: place operator force-save markers beside the host log, where
--   the live UE4SS process already has proven read/write access. Keep the
--   Windows Temp marker as a compatibility fallback and remove every scoped
--   copy after one successful native save request.
--   v0.18.31: support a port-scoped operator force-save marker. Resolve
--   Bellwright's reflected cheating component and invoke its native Auto-slot
--   save on the game thread, so recovery can be verified without a test player.
--   v0.18.30: continue the existing TEMP auto-save through Bellwright's native
--   travel options instead of opening Karvenia as a new game. Preserve the
--   listen port and paid player capacity on the same travel URL.
--   v0.18.29: require the safe UE4SS field sentinel and check IsValidField
--   before optional reflected property reads/writes. A missing field can appear
--   during UObject teardown/GC; never dereference that invalid-field sentinel.
--   v0.18.28: remove direct runtime mutation of live NPC Mutable components;
--   Bellwright can be inside an asynchronous skeletal-mesh update when those
--   UE4SS native calls fire, causing an uncatchable game-thread access violation.
--   Keep the safe cvar/render suppression only. Give native persistence a full
--   grace window before retrying HandleStartingNewPlayer so an existing player
--   record can resolve before the host drives the start handler again.
--   v0.18.27: preserve Bellwright's native persistent-player lifecycle. The
--   login URL's stable Name is consumed by InitNewPlayer before PostLogin; do
--   not overwrite PlayerState/controller/connection identity afterward. Retry
--   HandleStartingNewPlayer on the game thread while persistence finishes
--   loading instead of forcing RestartPlayer, which creates an unbound default
--   pawn with no AMistPlayer state. Leave streaming, movement, customization,
--   and cinematic readiness to Bellwright's normal player-start flow.
--   v0.18.26: strip the UTF-8 BOM from the first login-identity timestamp so
--   the first player after restart is immediately claimable. Keep the identity
--   grace beyond the 150s cache window and never re-service a quarantined PC.
--   v0.18.25: keep join/identity servicing alive when UE4SS transiently exposes
--   ClientConnections with a nil array count. Treat that tick as empty instead
--   of throwing out of serviceJoiners; later ticks resume the live connections.
--   v0.18.24: apply the paid player capacity to Bellwright's native GameSession.
--   Bellwright's hidden listen host consumes one native seat, so a 4-player
--   dedicated host needs MaxPlayers=5 to admit four real remote players. The
--   supervisor/A2S count remains 4 because the hidden host is never customer-visible.
--   v0.18.23: recency-claim fallback for the login identity cache. On some
--   endpoints UE4SS exposes BOTH UNetConnection.RequestURL and the remote
--   address as unreadable object proxies, so the v0.18.21 byAddress/byLogin
--   lookups can never match and the REAL joiner got quarantined after the 30s
--   grace (interactions dead and the pawn hidden server-side). Now an
--   unmatched live remote conn claims the oldest UNCLAIMED fresh (<150s) row
--   from login-identities.tsv — Bellwright's LogNet login and the controller
--   creation are seconds apart, so time-proximity is authoritative when direct
--   matching is blind. Each row is handed out once (claim registry), claims are
--   sticky per connection, and the pre-login grace is raised 30s -> 75s for
--   slow-loading clients. Genuinely identity-less controllers still quarantine.
--   v0.18.22: clear a stale roster at idle. writeRoster was only called when a
--   remote joiner was live, so after the last player left (or a restart) the last
--   non-empty roster.json persisted forever -> the launcher showed a phantom
--   "1 player, no name, always there" (often a pre-guard UScriptStruct identity).
--   Now the idle service loop refreshes the roster every ~9s so it self-clears to
--   players:[]; safe because the IpNetDriver scan is cheap under -nullrhi.
--   v0.18.21: use HearthServer's Bellwright LogNet login identity cache when
--   UE4SS exposes UNetConnection.RequestURL as a transient UObject proxy.
--   v0.18.20: guard diagnostic World.TimeSeconds math when UE4SS returns an
--   Unreal property proxy instead of a Lua number, so join servicing cannot throw.
--   v0.18.19: add a low-risk post-host liveness heartbeat and retire the
--   high-frequency travel-pin loop shortly after listen startup so repeated
--   UObject travel probes cannot wedge the Lua VM while the game keeps ticking.
--   v0.18.18: keep the post-travel host loop alive even when GameInstance lookup
--   disappears after OpenLevel, so idle heartbeat/join servicing continues.
--   v0.18.17: prefer the launcher's Steam-backed PlayerId / PlatformUserId over
--   generated ?Name values for reconnect/save identity.
--   v0.18.16: keep once-identified local host phantom controllers out of the
--   remote joiner path even if Bellwright later reports them as non-local.
--   v0.18.15: only spawn/possess controllers after a live NetConnection has a
--   stable Hearth login identity, and isolate stale pre-login controllers so
--   failed handshakes cannot become sleeping/interacting ghost players.
--   v0.18.14: reject transient UE object strings (UScriptStruct/UObject/etc.)
--   as player identities; clear them before spawn instead of saving them as
--   reconnect keys.
--   v0.18.13: reconnect/save identity fix — seed the joiner's PlayerState/PC string fields
--   from the direct-IP login URL before forced RestartPlayer, and stop roster ids from
--   falling back to transient UObject addresses.
--   v0.18.12: TICK-RATE fix — cache hot FindFirstOf lookups + kill the per-pass full-object bench scan; the continuous GUObjectArray walks (UObjectArrayCache off) held the UE4SS Lua lock ~100% and serialized every engine frame to ~1.5s (0.65fps, joiners frozen).
--   v0.18.11: roster/player-count fix — count every live ClientConnection, no longer
--   drop connections whose OSS=Null PlayerState name looks generated (the "0 of 4
--   forever" A2S count bug; name stays cosmetic, count is ground-truth connections).
-- Proven recipe (spike 2026-06-13 + on-box validation 2026-06-14):
--   1. Wait for a SETTLED main menu (the menu world name unchanged for >=6s, and >=18s elapsed).
--   2. swap NetDriverDefinitions[GameNetDriver] SteamSocketsNetDriver -> stock IpNetDriver
--   3. OpenLevel(GameInstance, NewGameMapName="Karvenia_08", true,
--      "listen?Port=<port>? -SaveFile=TEMP -SaveSlot=4 -SaveSuffix=")
--   -> binds UDP <port>, holds the listen world headless/no-Steam. A stock IpNetDriver client
--      firing `open <ip>:<port>` is Welcomed into Karvenia_08 and TravelCompletes in-world.
--
-- WHY THE SETTLED GATE (do not remove): under GPU/WARP render the menu runs its own level-load
-- on boot. Firing OpenLevel mid-init (the old ~3s phase==1 trigger) RACES that load -> the menu
-- wins -> CleanupWorld(Karvenia) -> bounce back to menu -> :port never binds. Waiting until the
-- menu is settled makes our OpenLevel the only load in flight, so the listen world holds.
--   Validated on-box 2026-06-14: settled fire at t=18 -> NetDriver valid + UDP 7777 bound at
--   t=21, held 60s+ with zero bounce; client joined as HumanGenome and rendered Karvenia.
--
-- Bellwright UE4SS truths for THIS build (do not "fix"):
--   - Engine-thread / tick detours FAIL on 5.7.4. Drive EVERYTHING from the LoopAsync async thread.
--   - The world map name lives in the reflection prop `NewGameMapName` (= "Karvenia_08" stock).
--   - Single net-driver definition: GameNetDriver -> /Script/SteamSockets.SteamSocketsNetDriver.
--   - Render: the host runs -nullrhi. The launcher verifies native patches that
--     bypass AMistMapFog's render-only texture work before the gameplay world loads.

local function getenv_file(envName, filePath, default)
    local v = os.getenv(envName)
    if v and #v > 0 then return v end
    if filePath then
        local f = io.open(filePath, "r")
        if f then local s = f:read("*l"); f:close(); if s then s = s:gsub("%s+", "") end
            if s and #s > 0 then return s end end
    end
    return default
end

local GAME_PORT  = getenv_file("HEARTH_GAME_PORT",  "C:\\Windows\\Temp\\hearth_game_port.txt",  "7777")
local WORLD_NAME = getenv_file("HEARTH_WORLD_NAME", "C:\\Windows\\Temp\\hearth_world_name.txt", nil)
local SAVE_FILE = os.getenv("HEARTH_SAVE_FILE")
local CUSTOMER_MAX_PLAYERS = tonumber(getenv_file("HEARTH_MAX_PLAYERS", "C:\\Windows\\Temp\\hearth_max_players.txt", "4")) or 4
CUSTOMER_MAX_PLAYERS = math.max(1, math.min(64, math.floor(CUSTOMER_MAX_PLAYERS)))
local NATIVE_MAX_PLAYERS = CUSTOMER_MAX_PLAYERS + 1
local ADMIN_AUTH = {
    ticketFile = os.getenv("HEARTH_ADMIN_TICKET_FILE"),
    configured = {},
    count = 0,
    pawnByPc = {},
    queuedByPc = {},
    unavailableByPc = {},
    deniedByPc = {},
    authorizedSteamByPc = {},
    consumedTickets = {},
    republishByPc = {},
}
for candidate in tostring(getenv_file("HEARTH_ADMIN_STEAM_IDS", nil, "")):gmatch("[^,%s]+") do
    if #candidate == 17 and candidate:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then
        ADMIN_AUTH.configured[candidate] = true
        ADMIN_AUTH.count = ADMIN_AUTH.count + 1
    end
end
local LOG = os.getenv("HEARTH_HOST_LOG") or os.getenv("BW_HOST_LOG")
if not LOG or #LOG == 0 then LOG = (os.getenv("LOCALAPPDATA") or "C:\\Temp") .. "\\bw_host.log" end
GAMEPLAY_SETTINGS = {
    file = os.getenv("HEARTH_GAMEPLAY_SETTINGS_FILE"),
    status = os.getenv("HEARTH_GAMEPLAY_SETTINGS_STATUS"),
    native = nil,
    queued = false,
    lastCheckT = -10,
    lastStatus = nil,
}

local function log(s)
    local line = "[bw_host] " .. tostring(s)
    pcall(print, line .. "\n")
    local f = io.open(LOG, "a"); if f then f:write(os.date("%H:%M:%S ") .. line .. "\r\n"); f:close() end
end

-- UE4SS invokes queued callbacks from its own native pcall/error-handler path.
-- On b50986bd, a callback error can enter luaL_traceback and crash while its
-- recursive name lookup walks Lua tables. Catch the callback inside Lua first,
-- then return normally to UE4SS. Queue failures and cleanup hooks stay explicit.
local function executeInGameThreadSafe(label, callback, onError)
    if type(ExecuteInGameThread) ~= "function" then return false, "unavailable" end
    local queued, queueErr = pcall(function()
        ExecuteInGameThread(function()
            local callbackOk, callbackErr = pcall(callback)
            if not callbackOk then
                log("game-thread callback failed label=" .. tostring(label)
                    .. " err=" .. tostring(callbackErr))
                if onError then pcall(onError, callbackErr) end
            end
        end)
    end)
    if not queued then
        log("game-thread callback queue failed label=" .. tostring(label)
            .. " err=" .. tostring(queueErr))
        if onError then pcall(onError, queueErr) end
    end
    return queued, queueErr
end
local function safeArrayNum(arr)
    if not arr then return 0 end
    local n = nil
    pcall(function() n = arr:GetArrayNum() end)
    n = tonumber(n)
    if not n or n < 0 then return 0 end
    return math.floor(n)
end

-- UE4SS b50986bd returns a special invalid-field userdata when a reflected
-- property/function does not exist. IsValidField distinguishes that sentinel
-- from a real field whose UObject value is currently null.
local function readOptionalField(obj, key)
    if obj == nil or type(key) ~= "string" then return nil, false end
    local ok, value = pcall(function() return obj[key] end)
    if not ok then return nil, false end

    local checker = nil
    pcall(function() checker = value and value.IsValidField end)
    if checker then
        local checkOk, validField = pcall(function() return value:IsValidField() end)
        if checkOk and validField == false then return nil, false end
    end
    return value, true
end

local function writeOptionalField(obj, key, value)
    local _, exists = readOptionalField(obj, key)
    if not exists then return false end
    return pcall(function() obj[key] = value end) and true or false
end

local function optionalFieldText(obj, key)
    local value, exists = readOptionalField(obj, key)
    if not exists then return "<missing>" end
    return tostring(value)
end

log("mod loaded v0.18.50  port=" .. tostring(GAME_PORT) .. " world=" .. tostring(WORLD_NAME)
    .. " customerMaxPlayers=" .. tostring(CUSTOMER_MAX_PLAYERS)
    .. " nativeMaxPlayers=" .. tostring(NATIVE_MAX_PLAYERS)
    .. " configuredAdmins=" .. tostring(ADMIN_AUTH.count)
    .. " saveFile=" .. tostring(SAVE_FILE)
    .. " gameplaySettings=" .. tostring(GAMEPLAY_SETTINGS.file)
    .. " gameplayStatus=" .. tostring(GAMEPLAY_SETTINGS.status))

-- ===========================================================================
-- NULLRHI FOG GUARD (v0.18.47). The host runs -nullrhi (no render pipeline
-- at all) instead of -d3d12 -WARP: under WARP the render thread cost ~1.5s/frame
-- regardless of scene or resolution, and the game thread waits on the render
-- fence every frame, capping the WHOLE fleet at ~0.65fps (frozen worlds for every
-- joiner). Under -nullrhi the engine ticks at the full frame cap (validated 30fps
-- steady, 2026-07-03). The v0.1.77 crash stack proved the remaining failure was
-- UMapRevealerComponent::UpdateMapFogAtLocation dereferencing its null Canvas.
-- The launcher now verifies that exact call-site patch together with the three
-- existing render/persistence/subregion patches. Only then may the MapFog actor
-- tick; every owned component remains disabled. Missing/stale patch evidence
-- retains the full guard. Completed Travel Signs keep their narrow repair path.
-- ===========================================================================
local fogSafety = {
    marker = os.getenv("HEARTH_MAP_FOG_PATCH_MARKER"),
    token = os.getenv("HEARTH_MAP_FOG_PATCH_TOKEN"),
    guardLogged = false,
    readyLogged = false,
}

fogSafety.patchesReady = function()
    if not fogSafety.marker or #fogSafety.marker == 0
        or not fogSafety.token or #fogSafety.token == 0 then
        return false
    end
    local f = io.open(fogSafety.marker, "r")
    if not f then return false end
    local token = f:read("*l")
    f:close()
    if not token then return false end
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    return token == fogSafety.token
end

fogSafety.disableComponents = function(obj)
    if not (obj and obj.IsValid and obj:IsValid()) then return end
    pcall(function()
        local comps = obj:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
        if comps then
            for _, c in ipairs(comps) do pcall(function() c:SetComponentTickEnabled(false) end) end
        end
    end)
end

local function neuterFogActor(obj)
    if not (obj and obj.IsValid and obj:IsValid()) then return end
    fogSafety.disableComponents(obj)
    pcall(function() obj:SetActorTickEnabled(false) end)
    local tick = readOptionalField(obj, "PrimaryActorTick")
    if tick then writeOptionalField(tick, "bCanEverTick", false) end
end

fogSafety.allowActorOnly = function(obj)
    if not (obj and obj.IsValid and obj:IsValid()) then return end
    fogSafety.disableComponents(obj)
    local tick = readOptionalField(obj, "PrimaryActorTick")
    if tick then writeOptionalField(tick, "bCanEverTick", true) end
    pcall(function() obj:SetActorTickEnabled(true) end)
end

local function guardFogActor(obj)
    if fogSafety.patchesReady() then
        fogSafety.allowActorOnly(obj)
        if not fogSafety.readyLogged then
            fogSafety.readyLogged = true
            log("nullrhi fog safety: four native patches verified; MapFog actor tick enabled; component ticks disabled")
        end
        return
    end
    neuterFogActor(obj)
    if not fogSafety.guardLogged then
        fogSafety.guardLogged = true
        log("nullrhi fog safety: native patches not verified; MapFog actor/component ticks disabled")
    end
end

for _, fogCls in ipairs({ "/Script/Mist.MapFog", "/Script/Mist.MistMapFog" }) do
    pcall(function()
        NotifyOnNewObject(fogCls, function(obj)
            guardFogActor(obj)
        end)
    end)
end
-- safety sweep for instances that predate the mod or respawn oddly
LoopAsync(5000, function()
    pcall(function()
        for _, cn in ipairs({ "MapFog", "MistMapFog" }) do
            for _, o in ipairs(safeFindAll(cn)) do
                pcall(function() guardFogActor(o) end)
            end
        end
    end)
    return false
end)

local function flagText(flags)
    local n = tonumber(flags) or 0
    local out = {}
    local function has(mask)
        return (math.floor(n / mask) % 2) == 1
    end
    local names = {
        { 0x00000040, "Net" },
        { 0x00000080, "NetReliable" },
        { 0x00000400, "Native" },
        { 0x00000800, "Event" },
        { 0x00004000, "NetMulticast" },
        { 0x00200000, "NetServer" },
        { 0x01000000, "NetClient" },
        { 0x04000000, "BlueprintCallable" },
        { 0x08000000, "BlueprintEvent" },
    }
    for _, p in ipairs(names) do
        if has(p[1]) then table.insert(out, p[2]) end
    end
    if #out == 0 then return tostring(flags) end
    return tostring(flags) .. " (" .. table.concat(out, "|") .. ")"
end

local function softPathStr(sp)
    local s = nil
    pcall(function()
        local assetPath = readOptionalField(sp, "AssetPath")
        local packageName = assetPath and readOptionalField(assetPath, "PackageName") or nil
        local v = packageName and packageName:ToString() or nil
        if v and v ~= "" and v ~= "None" then s = v end
    end)
    if s then return s end
    pcall(function()
        local assetPathName = readOptionalField(sp, "AssetPathName")
        local v = assetPathName and assetPathName:ToString() or nil
        if v and v ~= "" and v ~= "None" then s = v end
    end)
    return s
end

local function objFullName(obj)
    if not (obj and obj.IsValid and obj:IsValid()) then return "None" end
    local n = nil
    pcall(function() n = obj:GetFullName() end)
    if n and n ~= "" then return tostring(n) end
    pcall(function() n = obj:GetFName():ToString() end)
    if n and n ~= "" then return tostring(n) end
    return tostring(obj)
end

local function objClassName(obj)
    if not (obj and obj.IsValid and obj:IsValid()) then return "None" end
    local n = nil
    pcall(function() n = obj:GetClass():GetFName():ToString() end)
    return tostring(n or "Unknown")
end

local function safeFindAll(className)
    local ok, arr = pcall(function() return FindAllOf(className) end)
    if ok and arr then return arr end
    return {}
end

-- ===========================================================================
-- TRAVEL SIGN DISCOVERY (v0.18.39). MapFog cannot tick safely under null-RHI,
-- but Bellwright uses its server-side reveal state to discover map icons. Use
-- the game's own SetMapIconDiscovered API only for completed FastTravelSign_C
-- actors whose icon class derives from MistMapFastTravelIconComponent. This
-- preserves the normal replication/persistence notifications without revealing
-- unrelated POIs, quests, towns, or fog. Bellwright's icon provider ignores a
-- repeated true-only request after the sign was discovered before a remote
-- player's map manager existed, so replay a bounded false/true transition after
-- player-manager construction/possession and leave the final state discovered.
-- ===========================================================================
local travelSignRemotePlayerCount = 0
local travelSignRemotePlayers = {}   -- v0.18.50: pawn full names, never handles
local serviceTravelSignDiscovery, requestTravelSignPlayerSync, resetTravelSignDiscovery = (function()
-- v0.18.50: object handles must not outlive the tick that produced them.
-- GetFullName() is "Class /Path.Outer:Sub.Name"; StaticFindObject wants the
-- path without the class prefix. Resolve at the moment of use, on the thread
-- that uses it, and verify the class before handing the object to a UFunction.
local ObjRef = {}
ObjRef.pathFromFullName = function(fullName)
    if type(fullName) ~= "string" then return nil end
    local path = fullName:match("^%S+%s+(%S.*)$") or fullName
    if path == "" or path == "None" then return nil end
    if path:sub(1, 1) ~= "/" then return nil end
    return path
end

ObjRef.derivesFrom = function(obj, baseName)
    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    local current = cls
    for _ = 1, 24 do
        if not (current and current.IsValid and current:IsValid()) then return false end
        local name = nil
        pcall(function() name = current:GetFName():ToString() end)
        if tostring(name) == baseName then return true end
        local parent = nil
        pcall(function() parent = current:GetSuperStruct() end)
        current = parent
    end
    return false
end

ObjRef.resolve = function(fullName, baseClassName)
    local path = ObjRef.pathFromFullName(fullName)
    if not path then return nil end
    local obj = nil
    pcall(function() obj = StaticFindObject(path) end)
    if not (obj and obj.IsValid and obj:IsValid()) then return nil end
    if baseClassName and not ObjRef.derivesFrom(obj, baseClassName) then return nil end
    return obj
end

local travelSignPending = {}
local travelSignPendingByKey = {}
local travelSignSeen = {}
local travelSignComponentsByOwner = {}
local travelSignProvidersByOwner = {}
local travelSignProviderSeen = {}
local travelSignProviderPending = {}
local travelSignDiscoveryQueued = false
local travelSignDiscoveryNextT = 0
local travelSignScanState = { nextT = 0, count = 0 }
local TRAVEL_SIGN_DISCOVERY_RETRIES = 20
local TRAVEL_SIGN_PLAYER_SYNC_PASSES = 3
local TRAVEL_SIGN_PLAYER_SYNC_INTERVAL = 4
local travelSignPlayerSyncPasses = 0
local travelSignPlayerSyncNextT = 0
local travelSignPlayerSyncReason = "none"
local TRAVEL_SIGN_DISCOVERY_SCAN_PASSES = 8
local TRAVEL_SIGN_DISCOVERY_SCAN_INTERVAL = 60

local function travelSignObjectKey(obj)
    local key = objFullName(obj)
    if key == "None" or key == "" then key = tostring(obj) end
    return key
end

local function queueTravelSignKey(key, retries, playerSync)
    if type(key) ~= "string" or not ObjRef.pathFromFullName(key) then return end
    local pending = travelSignPendingByKey[key]
    if pending then
        if playerSync then pending.playerSync = true end
        return
    end
    if travelSignSeen[key] and not playerSync then return end
    travelSignSeen[key] = "pending"
    local item = {
        key = key,
        retries = retries or 0,
        playerSync = playerSync and true or false
    }
    travelSignPendingByKey[key] = item
    table.insert(travelSignPending, item)
end

local function queueTravelSignComponent(obj, retries, playerSync)
    if not (obj and obj.IsValid and obj:IsValid()) then return end
    queueTravelSignKey(travelSignObjectKey(obj), retries, playerSync)
end

local function ownerOf(obj)
    local owner = nil
    pcall(function() owner = obj:GetOwner() end)
    if owner and owner.IsValid and owner:IsValid() then return owner end
    return nil
end

local function rememberTravelSignComponent(component, owner)
    local ownerKey = travelSignObjectKey(owner)
    local componentKey = travelSignObjectKey(component)
    local components = travelSignComponentsByOwner[ownerKey]
    if not components then
        components = {}
        travelSignComponentsByOwner[ownerKey] = components
    end
    for _, existingKey in ipairs(components) do
        if existingKey == componentKey then return ownerKey end
    end
    table.insert(components, componentKey)
    return ownerKey
end

local function rememberTravelSignProvider(providerKey)
    local provider = ObjRef.resolve(providerKey, "MistMapIconProviderComponent")
    if not provider then return "invalid" end
    if travelSignProviderSeen[providerKey] then return "remembered" end

    local owner = ownerOf(provider)
    if not owner then return "wait" end
    if objClassName(owner) ~= "FastTravelSign_C" then
        travelSignProviderSeen[providerKey] = "ignored"
        return "ignored"
    end
    local ownerKey = travelSignObjectKey(owner)
    local providers = travelSignProvidersByOwner[ownerKey]
    if not providers then
        providers = {}
        travelSignProvidersByOwner[ownerKey] = providers
    end
    travelSignProviderSeen[providerKey] = true
    table.insert(providers, providerKey)

    -- A provider can be constructed well after its sibling fast-travel component.
    -- Re-arm only components belonging to this exact FastTravelSign actor.
    for _, componentKey in ipairs(travelSignComponentsByOwner[ownerKey] or {}) do
        travelSignSeen[componentKey] = nil
        queueTravelSignKey(componentKey, 0)
    end
    return "remembered"
end

local function queueTravelSignProvider(provider)
    if not (provider and provider.IsValid and provider:IsValid()) then return end
    local providerKey = travelSignObjectKey(provider)
    if not ObjRef.pathFromFullName(providerKey) then return end
    if travelSignProviderSeen[providerKey] or travelSignProviderPending[providerKey] then return end
    travelSignProviderPending[providerKey] = true
end

local function classDerivesFromNamed(cls, baseName)
    local current = cls
    for _ = 1, 16 do
        if not (current and current.IsValid and current:IsValid()) then return false end
        local name = nil
        pcall(function() name = current:GetFName():ToString() end)
        if tostring(name) == baseName then return true end
        local parent = nil
        pcall(function() parent = current:GetSuperStruct() end)
        current = parent
    end
    return false
end

local function retryTravelSignComponent(item, reason)
    if item.retries >= TRAVEL_SIGN_DISCOVERY_RETRIES then
        travelSignSeen[item.key] = "failed"
        log("travel sign discovery gave up key=" .. item.key .. " reason=" .. tostring(reason))
        return
    end
    travelSignSeen[item.key] = nil
    queueTravelSignKey(item.key, item.retries + 1, item.playerSync)
end

local function repairTravelSignComponent(item)
    -- Game thread. Resolve every object here, from its path, and never reuse a
    -- handle that was produced on the async loop or on an earlier tick.
    local component = ObjRef.resolve(item.key, "MistFastTravelComponent")
    if not component then
        travelSignSeen[item.key] = "invalid"
        return
    end

    local owner = ownerOf(component)
    if not owner then
        retryTravelSignComponent(item, "owner-not-ready")
        return
    end
    if objClassName(owner) ~= "FastTravelSign_C" then
        travelSignSeen[item.key] = "ignored-owner"
        return
    end
    local ownerKey = rememberTravelSignComponent(component, owner)

    local remainingUses = readOptionalField(component, "RemainingUses")
    if type(remainingUses) ~= "number" or remainingUses < 1 then
        retryTravelSignComponent(item, "not-complete")
        return
    end

    local providers = {}
    for _, providerKey in ipairs(travelSignProvidersByOwner[ownerKey] or {}) do
        local provider = ObjRef.resolve(providerKey, "MistMapIconProviderComponent")
        if provider and travelSignObjectKey(ownerOf(provider)) == ownerKey then
            table.insert(providers, provider)
        end
    end
    if #providers < 1 then
        retryTravelSignComponent(item, "provider-not-ready")
        return
    end

    local library = StaticFindObject("/Script/Mist.Default__MistBlueprintLibrary")
    if not (library and library.IsValid and library:IsValid()) then
        retryTravelSignComponent(item, "blueprint-library-missing")
        return
    end

    local repaired = 0
    local rejected = 0
    local classes = {}
    local notReady = 0
    local roadGraphRefreshed = false
    local playerRepairs = 0
    local playerSync = item.playerSync or travelSignRemotePlayerCount > 0
    if playerSync then
        for _, playerKey in ipairs(travelSignRemotePlayers) do
            local player = ObjRef.resolve(playerKey, "Pawn")
            if player then
                local playerOk, playerErr = pcall(function()
                    player:ServerRepairTravelComponent(component)
                end)
                if playerOk then
                    playerRepairs = playerRepairs + 1
                else
                    log("travel sign player repair RPC failed owner=" .. objFullName(owner)
                        .. " player=" .. objFullName(player)
                        .. " err=" .. tostring(playerErr))
                end
            end
        end
        local roadOk, roadErr = pcall(function()
            component:HandleRoadGraphUpdate()
        end)
        if roadOk then
            roadGraphRefreshed = true
        else
            log("travel sign player sync road-graph call failed owner=" .. objFullName(owner)
                .. " err=" .. tostring(roadErr))
        end
    end
    for _, provider in ipairs(providers) do
        if provider and provider.IsValid and provider:IsValid() then
            local iconClass = readOptionalField(provider, "MapIconClass")
            if iconClass and iconClass.IsValid and iconClass:IsValid()
                and classDerivesFromNamed(iconClass, "MistMapFastTravelIconComponent") then
                local iconName = objFullName(iconClass)
                local ok, err = pcall(function()
                    if playerSync then
                        library:SetMapIconDiscovered(iconClass, false)
                    end
                    library:SetMapIconDiscovered(iconClass, true)
                end)
                if ok then
                    repaired = repaired + 1
                    table.insert(classes, iconName)
                else
                    log("travel sign discovery call failed owner=" .. objFullName(owner)
                        .. " icon=" .. iconName .. " err=" .. tostring(err))
                end
            elseif iconClass and iconClass.IsValid and iconClass:IsValid() then
                rejected = rejected + 1
            else
                notReady = notReady + 1
            end
        end
    end

    if repaired < 1 then
        if rejected > 0 and notReady == 0 then
            travelSignSeen[item.key] = "rejected-icon-scope"
            log("travel sign discovery refused non-fast-travel icon owner=" .. objFullName(owner))
        else
            retryTravelSignComponent(item, "icon-class-not-ready")
        end
        return
    end

    travelSignSeen[item.key] = "repaired"
    log("travel sign discovery repaired owner=" .. objFullName(owner)
        .. " remainingUses=" .. tostring(remainingUses)
        .. " providers=" .. tostring(repaired)
        .. " playerSync=" .. tostring(playerSync)
        .. " playerRepairs=" .. tostring(playerRepairs)
        .. " roadGraph=" .. tostring(roadGraphRefreshed)
        .. " iconClasses=" .. table.concat(classes, ","))
end

local function requestTravelSignPlayerSyncImpl(reason)
    travelSignPlayerSyncPasses = TRAVEL_SIGN_PLAYER_SYNC_PASSES
    travelSignPlayerSyncNextT = 0
    travelSignPlayerSyncReason = tostring(reason or "player-ready")
    log("travel sign player sync scheduled reason=" .. travelSignPlayerSyncReason
        .. " passes=" .. tostring(TRAVEL_SIGN_PLAYER_SYNC_PASSES))
end

local function queueTravelSignPlayerSyncPass(passNumber)
    local queued = 0
    for _, components in pairs(travelSignComponentsByOwner) do
        for _, componentKey in ipairs(components) do
            travelSignSeen[componentKey] = nil
            queueTravelSignKey(componentKey, 0, true)
            queued = queued + 1
        end
    end
    -- Always sweep the world too, not only when nothing has been remembered yet.
    -- The old "queued < 1" guard meant that as soon as a single sign was known,
    -- this stopped looking, so a server that found one sign at boot stayed on
    -- that one sign for its whole life while the rest stayed invisible.
    local swept = 0
    for _, component in ipairs(safeFindAll("MistFastTravelComponent")) do
        queueTravelSignComponent(component, 0, true)
        swept = swept + 1
    end
    log("travel sign player sync queued reason=" .. travelSignPlayerSyncReason
        .. " pass=" .. tostring(passNumber)
        .. " components=" .. tostring(queued)
        .. " swept=" .. tostring(swept))
end

local function serviceTravelSignDiscoveryImpl(now)
    if travelSignDiscoveryQueued or now < travelSignDiscoveryNextT then return end
    travelSignDiscoveryNextT = now + 3

    for providerKey in pairs(travelSignProviderPending) do
        local result = rememberTravelSignProvider(providerKey)
        if result ~= "wait" then travelSignProviderPending[providerKey] = nil end
    end

    if travelSignScanState.count < TRAVEL_SIGN_DISCOVERY_SCAN_PASSES
        and now >= travelSignScanState.nextT then
        travelSignScanState.nextT = now + TRAVEL_SIGN_DISCOVERY_SCAN_INTERVAL
        travelSignScanState.count = travelSignScanState.count + 1
        -- A single early pass missed late-spawned components on loaded saves.
        -- Keep a bounded startup window, then rely on the object hooks above.
        -- A lifetime sweep walks roughly 2,500 unrelated providers every minute
        -- and needlessly exercises the UE4SS Lua/UObject boundary. Clear the
        -- give-up markers during this startup window: "failed" here usually
        -- means the owning actor was not ready yet, not a permanent failure.
        -- On a loaded save the Fast Travel
        -- components can spawn after that first sweep, and a live server logged
        -- components=0 providers=820 for its only scan, so the signs that arrived
        -- a moment later were never looked at again.
        for key, state in pairs(travelSignSeen) do
            if state == "failed" then travelSignSeen[key] = nil end
        end
        local providers = safeFindAll("MistMapIconProviderComponent")
        for _, provider in ipairs(providers) do queueTravelSignProvider(provider) end
        local components = safeFindAll("MistFastTravelComponent")
        for _, component in ipairs(components) do queueTravelSignComponent(component, 0) end
        log("travel sign discovery scan pass=" .. tostring(travelSignScanState.count)
            .. " components=" .. tostring(#components)
            .. " providers=" .. tostring(#providers))
        if travelSignScanState.count >= TRAVEL_SIGN_DISCOVERY_SCAN_PASSES then
            log("travel sign discovery startup scan complete passes="
                .. tostring(TRAVEL_SIGN_DISCOVERY_SCAN_PASSES)
                .. " (runtime object hooks remain active)")
        end
    end
    if travelSignPlayerSyncPasses > 0 and now >= travelSignPlayerSyncNextT then
        local passNumber = TRAVEL_SIGN_PLAYER_SYNC_PASSES - travelSignPlayerSyncPasses + 1
        queueTravelSignPlayerSyncPass(passNumber)
        travelSignPlayerSyncPasses = travelSignPlayerSyncPasses - 1
        travelSignPlayerSyncNextT = now + TRAVEL_SIGN_PLAYER_SYNC_INTERVAL
    end
    if #travelSignPending == 0 or type(ExecuteInGameThread) ~= "function" then return end

    local batch = travelSignPending
    travelSignPending = {}
    travelSignDiscoveryQueued = true
    local queued, err = executeInGameThreadSafe("travel-sign-discovery", function()
        for _, item in ipairs(batch) do
            travelSignPendingByKey[item.key] = nil
            local ok, itemErr = pcall(function() repairTravelSignComponent(item) end)
            if not ok then retryTravelSignComponent(item, itemErr) end
        end
        travelSignDiscoveryQueued = false
    end, function(callbackErr)
        travelSignDiscoveryQueued = false
        for _, item in ipairs(batch) do
            travelSignPendingByKey[item.key] = nil
            retryTravelSignComponent(item, callbackErr)
        end
    end)
    if not queued then
        log("travel sign discovery batch was not queued err=" .. tostring(err))
    end
end

local travelSignNotifyOk, travelSignNotifyErr = pcall(function()
    NotifyOnNewObject("/Script/Mist.MistFastTravelComponent", function(obj)
        queueTravelSignComponent(obj, 0)
    end)
end)
if travelSignNotifyOk then
    log("travel sign discovery object hook registered")
else
    log("travel sign discovery object hook unavailable: " .. tostring(travelSignNotifyErr))
end
local providerNotifyOk, providerNotifyErr = pcall(function()
    NotifyOnNewObject("/Script/Mist.MistMapIconProviderComponent", function(obj)
        queueTravelSignProvider(obj)
    end)
end)
if providerNotifyOk then
    log("travel sign discovery provider hook registered")
else
    log("travel sign discovery provider hook unavailable: " .. tostring(providerNotifyErr))
end
local playerMapManagerNotifyOk, playerMapManagerNotifyErr = pcall(function()
    NotifyOnNewObject("/Script/Mist.MistPlayerMapIconManagerComponent", function()
        requestTravelSignPlayerSyncImpl("player-map-manager-created")
    end)
end)
if playerMapManagerNotifyOk then
    log("travel sign discovery player-map-manager hook registered")
else
    log("travel sign discovery player-map-manager hook unavailable: "
        .. tostring(playerMapManagerNotifyErr))
end
-- v0.18.50: the world was replaced (ServerTravel to the Halmare Isles and
-- back, or any other map change). Every remembered path names an object of the
-- old world, so forget all of it and run the startup sweep again.
local function resetTravelSignDiscoveryImpl(reason)
    travelSignPending = {}
    travelSignPendingByKey = {}
    travelSignSeen = {}
    travelSignComponentsByOwner = {}
    travelSignProvidersByOwner = {}
    travelSignProviderSeen = {}
    travelSignProviderPending = {}
    travelSignDiscoveryQueued = false
    travelSignDiscoveryNextT = 0
    travelSignScanState = { nextT = 0, count = 0 }
    log("travel sign discovery reset reason=" .. tostring(reason) .. " (startup sweep re-armed)")
    requestTravelSignPlayerSyncImpl(tostring(reason))
end

return serviceTravelSignDiscoveryImpl, requestTravelSignPlayerSyncImpl, resetTravelSignDiscoveryImpl
end)()

-- CACHED OBJECT LOOKUPS (v0.18.12 tick-rate fix). With bUseUObjectArrayCache=false
-- every FindFirstOf/FindAllOf is a full linear GUObjectArray walk (~350k objects)
-- that holds the UE4SS Lua lock. The 250ms fastpin loop + the 1.5s main loop called
-- these every pass, so the lock was held nearly continuously and every engine frame
-- that touches Lua (game-thread queue) stalled behind a scan -> the world ticked at
-- the scan cadence (~0.65fps fleet-wide; joiners saw a frozen/black world). The hot
-- objects are stable for the lifetime of the world, so resolve ONCE and revalidate
-- with IsValid(); rescan only when the ref dies (world/GM swap at host-up is also
-- handled by an explicit cache clear).
local objCache = {}
local function cachedFirst(className)
    local c = objCache[className]
    if c ~= nil then
        local valid = false
        pcall(function() valid = c:IsValid() end)
        if valid then return c end
        objCache[className] = nil
    end
    local o = nil
    pcall(function() o = FindFirstOf(className) end)
    if o and o:IsValid() then objCache[className] = o; return o end
    return nil
end
local function clearObjCache()
    objCache = {}
end

local function executeHostConsole(cmd)
    local ok = false
    pcall(function()
        local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local worlds = safeFindAll("World")
        local w = nil
        for _, candidate in ipairs(worlds) do
            if candidate and candidate:IsValid() then w = candidate; break end
        end
        if ks and ks:IsValid() and w and w:IsValid() then
            ks:ExecuteConsoleCommand(w, cmd, nil)
            ok = true
        end
    end)
    return ok
end

local function worldName()
    local w = cachedFirst("World")
    if not (w and w:IsValid()) then return "<noworld>" end
    local n = "?"; pcall(function() n = w:GetFullName() end); return n
end

-- Pin the world that actually carries the live GameNetDriver (the listen world).
-- Before the driver exists this rescans each call (short pre-host phase only);
-- once found it is cached and only rescanned if the world or driver dies.
local netWorld = nil
local function netDriverValid()
    if netWorld ~= nil then
        local v = false
        pcall(function()
            if netWorld:IsValid() then
                local nd = readOptionalField(netWorld, "NetDriver")
                v = (nd and nd:IsValid()) and true or false
            end
        end)
        if v then return true end
        netWorld = nil
    end
    for _, w in ipairs(safeFindAll("World")) do
        if w and w:IsValid() then
            local v = false
            pcall(function()
                local nd = readOptionalField(w, "NetDriver")
                v = (nd and nd:IsValid()) and true or false
            end)
            if v then netWorld = w; return true end
        end
    end
    return false
end

-- ===========================================================================
-- SERVER-SIDE CONNECTION TIMEOUT (v0.15.0) — THE real "dropped at ~69s" fix.
-- Under WARP the host GAME THREAD STALLS hard while WorldPartition streams the
-- open Karvenia world (host log: DriverTime 28.5 of 69.5s real). While stalled
-- the GameNetDriver doesn't tick, the joiner's keep-alive isn't processed, and
-- the SERVER-side UNetConnection::Tick fires its default 60s ConnectionTimeout
-- ("Connection TIMED OUT ... IsServer: YES ... Threshold: 60.00") -> the client
-- is dropped right before the game-thread possess can land = "renders the world,
-- no control, dropped at 69s". We already raised the CLIENT side to 600 (launcher
-- ConnectFlow); this raises the SERVER/HOST side too.
--
-- Config gets wiped (Steam/UE rewrites Engine.ini), so the runtime CDO set on
-- /Script/OnlineSubsystemUtils.Default__IpNetDriver is the decisive path (every
-- IpNetDriver constructed after this reads it), AND we also stamp every LIVE
-- IpNetDriver instance. Mirror of Beacon's BeaconServerRuntime tune_ip_net_driver.
-- Re-asserted periodically: the GameNetDriver is constructed AFTER our OpenLevel
-- listen swap, so a one-shot CDO set isn't enough on its own — keep stamping.
local NET_TIMEOUT = 600.0
local NET_RATE = 2097152
local NET_TOTAL = 16777216
local NET_MIN = 524288

local function set_prop(obj, key, value)
    if not (obj and obj.IsValid and obj:IsValid()) then return false end
    return writeOptionalField(obj, key, value)
end

local function tuneIpNetDriver(driver)
    if not (driver and driver.IsValid and driver:IsValid()) then return false end
    local changed = false
    if set_prop(driver, "ConnectionTimeout", NET_TIMEOUT) then changed = true end
    if set_prop(driver, "InitialConnectTimeout", NET_TIMEOUT) then changed = true end
    if set_prop(driver, "MaxClientRate", NET_RATE) then changed = true end
    if set_prop(driver, "MaxInternetClientRate", NET_RATE) then changed = true end
    if set_prop(driver, "ServerDesiredSocketReceiveBufferBytes", 4194304) then changed = true end
    if set_prop(driver, "ServerDesiredSocketSendBufferBytes", 4194304) then changed = true end
    if set_prop(driver, "ClientDesiredSocketReceiveBufferBytes", NET_RATE) then changed = true end
    if set_prop(driver, "ClientDesiredSocketSendBufferBytes", NET_RATE) then changed = true end
    return changed
end

-- Read back the live GameNetDriver / any IpNetDriver ConnectionTimeout for proof.
local function reportNetTuning()
    local vals = {}
    pcall(function()
        local cdo = StaticFindObject("/Script/OnlineSubsystemUtils.Default__IpNetDriver")
        if cdo and cdo:IsValid() then
            local ct = optionalFieldText(cdo, "ConnectionTimeout")
            local it = optionalFieldText(cdo, "InitialConnectTimeout")
            local mcr = optionalFieldText(cdo, "MaxClientRate")
            local micr = optionalFieldText(cdo, "MaxInternetClientRate")
            table.insert(vals, "CDO ConnectionTimeout=" .. ct .. " InitialConnectTimeout=" .. it .. " MaxClientRate=" .. mcr .. " MaxInternetClientRate=" .. micr)
        end
    end)
    pcall(function()
        local drivers = FindAllOf("IpNetDriver") or {}
        for _, d in ipairs(drivers) do
            if d and d:IsValid() then
                local nm = "?"; pcall(function() nm = d:GetFName():ToString() end)
                local ct = optionalFieldText(d, "ConnectionTimeout")
                local it = optionalFieldText(d, "InitialConnectTimeout")
                local mcr = optionalFieldText(d, "MaxClientRate")
                local micr = optionalFieldText(d, "MaxInternetClientRate")
                table.insert(vals, "live[" .. nm .. "] ConnectionTimeout=" .. ct .. " InitialConnectTimeout=" .. it .. " MaxClientRate=" .. mcr .. " MaxInternetClientRate=" .. micr)
            end
        end
    end)
    pcall(function()
        local player = StaticFindObject("/Script/Engine.Default__Player")
        if player and player:IsValid() then
            local ci = optionalFieldText(player, "ConfiguredInternetSpeed")
            local cl = optionalFieldText(player, "ConfiguredLanSpeed")
            table.insert(vals, "Player ConfiguredInternetSpeed=" .. ci .. " ConfiguredLanSpeed=" .. cl)
        end
    end)
    pcall(function()
        local manager = StaticFindObject("/Script/Engine.Default__GameNetworkManager")
        if manager and manager:IsValid() then
            local total = optionalFieldText(manager, "TotalNetBandwidth")
            local max = optionalFieldText(manager, "MaxDynamicBandwidth")
            local min = optionalFieldText(manager, "MinDynamicBandwidth")
            table.insert(vals, "GameNetworkManager TotalNetBandwidth=" .. total .. " MaxDynamicBandwidth=" .. max .. " MinDynamicBandwidth=" .. min)
        end
    end)
    if #vals == 0 then return "<no IpNetDriver found>" end
    return table.concat(vals, " | ")
end

local netTimeoutEverSet = false
local function applyNetTuning()
    local touched = 0
    -- CDO first (every driver constructed afterward inherits it; config-wipe-proof)
    pcall(function()
        if tuneIpNetDriver(StaticFindObject("/Script/OnlineSubsystemUtils.Default__IpNetDriver")) then touched = touched + 1 end
    end)
    -- then every live instance (the actual GameNetDriver serving the listen world)
    pcall(function()
        for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do
            if tuneIpNetDriver(d) then touched = touched + 1 end
        end
    end)
    pcall(function()
        local player = StaticFindObject("/Script/Engine.Default__Player")
        if player and player:IsValid() then
            set_prop(player, "ConfiguredInternetSpeed", NET_RATE)
            set_prop(player, "ConfiguredLanSpeed", NET_RATE)
        end
    end)
    pcall(function()
        local manager = StaticFindObject("/Script/Engine.Default__GameNetworkManager")
        if manager and manager:IsValid() then
            set_prop(manager, "TotalNetBandwidth", NET_TOTAL)
            set_prop(manager, "MaxDynamicBandwidth", NET_RATE)
            set_prop(manager, "MinDynamicBandwidth", NET_MIN)
        end
    end)
    if touched > 0 and not netTimeoutEverSet then
        netTimeoutEverSet = true
        log("net tuning -> timeout 600s + 2MiB/s rates set (CDO + live); now: " .. reportNetTuning())
    end
    return touched
end

local function swapNetDriver()
    local eng = FindFirstOf("GameEngine")
    if not (eng and eng:IsValid()) then log("swap: no engine"); return false end
    local swapped = false
    pcall(function()
        local defs = readOptionalField(eng, "NetDriverDefinitions")
        for i = 1, safeArrayNum(defs) do
            local d = defs[i]
            local defName = readOptionalField(d, "DefName")
            if defName and defName:ToString() == "GameNetDriver" then
                local classSet = writeOptionalField(d, "DriverClassName", FName("/Script/OnlineSubsystemUtils.IpNetDriver"))
                local fallbackSet = writeOptionalField(d, "DriverClassNameFallback", FName("/Script/OnlineSubsystemUtils.IpNetDriver"))
                swapped = classSet and fallbackSet
                if swapped then log("swapped GameNetDriver -> IpNetDriver") end
            end
        end
    end)
    return swapped
end

-- The full Karvenia package path (build 23876278+). On older builds the short name
-- "Karvenia_08" / the NewGameMapName reflection prop resolved; on 23876278 the map moved
-- into a nested iostore folder, so the short name + NewGameMapName both fall back to the
-- engine boot map /Engine/Maps/Entry -> the host serves an EMPTY world. The launcher sets the
-- real path via HEARTH_WORLD_NAME (WORLD_NAME), but this constant is the in-mod safety net so a
-- missing override never silently boots the empty world again. Re-derive per Steam patch.
local KARVENIA_FULL = "/Game/Mist/Maps/Karvenia/Karvenia_08/Karvenia_08"

-- Never a real gameplay world — if NewGameMapName/ServerDefaultMap resolve here, ignore them.
local function isBootMap(v)
    if not v then return true end
    local s = tostring(v)
    return s == "" or s == "None" or s:find("/Engine/Maps/Entry", 1, true) ~= nil or s == "Entry"
end

-- Resolve the world map to host: configured world (HEARTH_WORLD_NAME) > NewGameMapName /
-- ServerDefaultMap (ONLY if they name a real world, not the boot map) > full Karvenia path.
local function resolveWorld()
    if WORLD_NAME and #WORLD_NAME > 0 then return WORLD_NAME end
    local gi = FindFirstOf("GameInstance")
    if gi and gi:IsValid() then
        local ok, v = pcall(function()
            local mapName = readOptionalField(gi, "NewGameMapName")
            return mapName and mapName:ToString() or nil
        end)
        if ok and not isBootMap(v) then return v end
    end
    local ms = StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
    if ms and ms:IsValid() then
        local serverDefaultMap = readOptionalField(ms, "ServerDefaultMap")
        local sdm = serverDefaultMap and softPathStr(serverDefaultMap) or nil
        if not isBootMap(sdm) then return sdm end
    end
    return KARVENIA_FULL
end

-- ===========================================================================
-- WARP RENDER/SIM SUPPRESSION (v0.16.0) — THE no-GPU tick-starvation fix.
-- On a no-GPU WARP box the netdriver was ticking only once per 6-12s ("Very long
-- time between ticks. Realtime: 6-11s"). Root cause (UE abslog 2026-06-17):
-- the game thread blocks ~6s/frame because (a) WARP rasterizes the scene on the CPU
-- and the game thread waits a frame behind the render thread, and (b) the living
-- world simulation bakes NPC characters every frame -- LogMutable "Update Skeletal
-- Mesh Async CO_Human" + hundreds of UMistMutableFunctionLibrary::SetRandomParams
-- (TaxPatrol / Highland Robber NPC parties). The Mutable runtime mesh+texture
-- compositing is the dominant per-frame cost under software rendering.
-- A headless host renders nothing a human sees, so we drive the cheapest possible
-- frame: collapse the render surface, kill the expensive scene features, and -- the
-- big one -- stop Mutable from doing runtime skeletal-mesh/texture generation.
-- These are applied via the engine console (KismetSystemLibrary:ExecuteConsoleCommand)
-- AFTER the listen world is up, and re-applied periodically because a map load / the
-- game's own config can reset cvars.  We do NOT use a fixed-timestep (-FPS=): that
-- never sleeps and would keep the CPU pegged; a low t.MaxFPS lets the loop idle.
-- SAFE cvar set ONLY.  HARD-WON (on-box 2026-06-17): cvars that RESIZE the swapchain
-- or RELEASE render targets at runtime DEADLOCK the WARP host.  `r.SetRes 32x32w` plus
-- the render-target-releasing feature toggles tore down the MistMapFog render target
-- ("render target has been released") and forced a PSO recompile -> the game process
-- froze at 0% CPU (the exact AMistMapFog hazard the spike warned about).  So this set
-- NEVER changes resolution and NEVER touches features that own a persistent RenderTarget
-- (SkyAtmosphere/VolumetricFog/Fog/MapFog).  It ONLY lowers per-frame WORK that does not
-- reallocate render resources: frame cap, LOD/quality scalars, texture-streaming budget,
-- and -- the dominant cost -- Mutable runtime skeletal-mesh/texture generation.  All
-- applied on the GAME THREAD via ExecuteInGameThread (running ExecuteConsoleCommand from
-- the async LoopAsync thread is what hard-stalled the VM in the first place; cvar sets
-- that touch the renderer must run in engine context, same rule as RestartPlayer).
local renderCvars = {
    -- ★ THE REAL LEVER (on-box 2026-06-17): a headless WARP window is NEVER in the
    -- foreground, and UE THROTTLES the entire engine loop when unfocused. With Slate
    -- throttling on, the engine deliberately sleeps the game thread to a few FPS even
    -- though render/sim work is tiny -> the net TickDispatch fires only every several
    -- seconds. r.ScreenPercentage / view-distance cuts didn't move it because the frame
    -- wasn't render-bound -- it was THROTTLE-bound. Disable every unfocused/idle throttle
    -- so the game thread runs at the t.MaxFPS cap regardless of window focus.
    "Slate.bAllowThrottling 0",
    "t.IdleWhenNotForeground 0",
    "t.UnacceptableFrameTimeThreshold 100",
    "t.FPSMaxOutsideEditor 0",
    -- frame pacing: cap so the loop idles BETWEEN frames at this rate (no fixed-timestep,
    -- which never sleeps). 30 gives a sub-second net tick with plenty of CPU headroom.
    "t.MaxFPS 30",
    -- ★ RENDER-FENCE DECOUPLE (on-box 2026-06-17): per-thread sampling showed NO saturated
    -- thread (busiest ~60% of one core) yet 2.7-4.5s/frame -> the game thread is BLOCKED on
    -- the render fence each frame, not CPU-bound. WARP's Present is slow, and the game thread
    -- waits on FlushRenderingCommands. Run the renderer single-threaded + bypass the RHI
    -- command thread so Present happens inline (no cross-thread fence the game thread blocks
    -- on). This is what lets the net tick advance without waiting seconds for the previous
    -- WARP frame to present.
    -- ★ 2026-07-02 RCA (fleet-wide 0.1-0.6fps host tick): OneFrameThreadLag MUST be 1.
    -- 0 means "do NOT allow the render thread to lag" -> FFrameEndSync waits for the
    -- CURRENT frame's render completion every frame (proven by live minidumps: game thread
    -- parked in FFrameEndSync::PipelineFences -> FRenderCommandFence::Wait on all boxes).
    -- 1 (engine default) lets the game thread run a frame ahead of slow WARP presents.
    "r.OneFrameThreadLag 1",
    "r.GTSyncType 0",
    "r.VSync 0",
    "r.FinishCurrentFrame 0",
    "r.GPUStatsEnabled 0",
    "r.RHICmdBypass 1",
    -- THE DECISIVE RENDER CUT (on-box 2026-06-17): with a quiet world the frame is gated
    -- purely on WARP rasterizing Karvenia (~2.3s/frame). r.ScreenPercentage at runtime is
    -- SAFE (it does NOT release a render target / resize the swapchain, unlike r.SetRes) and
    -- collapses the rasterized pixel count ~100x. Paired with near-zero view distance the
    -- per-frame geometry + raster work drops enough for the engine to tick sub-second.
    "r.ScreenPercentage 1",
    "r.ViewDistanceScale 0.05",
    "r.SkeletalMeshLODBias 8",
    "r.StaticMeshLODDistanceScale 16",
    "r.DetailMode 0",
    "r.ShadowQuality 0",
    "r.MotionBlurQuality 0",
    "r.BloomQuality 0",
    "r.PostProcessAAQuality 0",
    "r.DepthOfFieldQuality 0",
    "r.SSR.Quality 0",
    "r.AllowOcclusionQueries 0",
    "foliage.DensityScale 0",
    "grass.DensityScale 0",
    -- texture streaming: small budget -> fewer resident textures, cheap WARP uploads
    "r.MipMapLODBias 6",
    "r.Streaming.LimitPoolSizeToVRAM 0",
    -- WorldPartition: don't block the game thread on slow WARP streaming
    "wp.Runtime.BlockOnSlowStreaming 0",
    -- stop Mutable runtime skeletal-mesh + texture generation (the NPC-bake cost during
    -- world population; subsides once settled but kept off so a respawn wave can't re-stall)
    "mutable.EnableSkeletalMeshUpdate 0",
    "mutable.SkipResourceGenerationOnConstruction 1",
    "mutable.MaxTextureSizeToGenerate 64",
    "mutable.EnableMutableLiveUpdateMode 0",
    "mutable.EnableMutableProgressiveMipStreaming 0",
}
local renderCvarsEverApplied = false
local renderCvarsApplyQueued = false
local function applyRenderCvars()
    if renderCvarsEverApplied or renderCvarsApplyQueued then return true end
    if type(ExecuteInGameThread) ~= "function" then return false end
    -- run on the game thread; cvar sets that reach the renderer must NOT run from the
    -- async LoopAsync thread (that hard-stalls the UE4SS Lua VM on this 5.7 build).
    renderCvarsApplyQueued = true
    local queued = executeInGameThreadSafe("apply-render-cvars", function()
        local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local w = FindFirstOf("World")
        if not (ks and ks:IsValid() and w and w:IsValid()) then renderCvarsApplyQueued = false; return end
        local n = 0
        for _, cmd in ipairs(renderCvars) do
            if pcall(function() ks:ExecuteConsoleCommand(w, cmd, nil) end) then n = n + 1 end
        end
        -- v0.18.43: only when this instance has a configured admin. Push model lets
        -- the replication system skip comparing an undirtied property, so the
        -- authenticated bIsHostPlayer write never reaches the owning client. This
        -- runs BEFORE OpenLevel so the listen server's rep layouts are built with
        -- push model off; the per-write MarkPropertyDirty below is the precise
        -- half, this is the one that does not depend on a reflected helper.
        local pushModelOff = false
        if ADMIN_AUTH.count > 0 then
            pushModelOff = pcall(function() ks:ExecuteConsoleCommand(w, "net.IsPushModelEnabled 0", nil) end)
        end
        renderCvarsEverApplied = true
        renderCvarsApplyQueued = false
        local f = io.open(LOG, "a")
        if f then f:write(os.date("%H:%M:%S ").."[bw_host] WARP render/sim suppression applied on game thread ("..n.." safe cvars; Mutable mesh-gen + LOD/streaming floor, NO resolution/render-target change)\r\n"); f:close() end
        if ADMIN_AUTH.count > 0 then
            local g = io.open(LOG, "a")
            if g then g:write(os.date("%H:%M:%S ").."[bw_host] admin replication: pre-host net.IsPushModelEnabled 0 applied="..tostring(pushModelOff).."\r\n"); g:close() end
        end
    end, function() renderCvarsApplyQueued = false end)
    if not queued then renderCvarsApplyQueued = false end
    return true
end

-- ★ DECOUPLE NET TICK FROM RENDER (v0.16.5) — the decisive headless lever.
-- Per-thread sampling proved the game thread is BLOCKED on the render frame each tick
-- (idle CPU, ~4.5s/frame) — WARP rasterizing Karvenia is the long pole and no render
-- cvar moved it. The game thread does not need the world drawn at all (headless host).
-- UGameViewportClient.bDisableWorldRendering = true tells the viewport to SKIP drawing
-- the scene entirely while the engine keeps ticking the world + the GameNetDriver. With
-- nothing to rasterize, the frame completes immediately and the net tick advances
-- sub-second. This is the standard "render nothing" path for a UE listen-server on a
-- software rasterizer — distinct from -nullrhi (which AVs MapFog): the RHI still exists,
-- we just don't submit the scene. Re-asserted (the viewport can be recreated).
local worldRenderDisabledLogged = false
local function disableWorldRendering()
    if type(ExecuteInGameThread) ~= "function" then return false end
    executeInGameThreadSafe("disable-world-rendering", function()
        local n = 0
        for _, vc in ipairs(FindAllOf("GameViewportClient") or {}) do
            if vc and vc:IsValid() then
                if writeOptionalField(vc, "bDisableWorldRendering", true) then n = n + 1 end
            end
        end
        if n > 0 and not worldRenderDisabledLogged then
            worldRenderDisabledLogged = true
            local f = io.open(LOG, "a")
            if f then f:write(os.date("%H:%M:%S ").."[bw_host] world rendering DISABLED on "..n.." viewport(s) (bDisableWorldRendering=true) -> net tick decoupled from WARP render\r\n"); f:close() end
        end
    end)
    return true
end

local lastWorldRenderDisableT = -100
local WORLD_RENDER_DISABLE_INTERVAL = 15.0

local function hasExistingAutoSave()
    if not (SAVE_FILE and #SAVE_FILE > 0) then return false end
    local f = io.open(SAVE_FILE, "rb")
    if not f then return false end
    local size = f:seek("end") or 0
    f:close()
    return size > 0
end

local function doHost()
    applyRenderCvars()
    disableWorldRendering()
    swapNetDriver()
    -- bump the IpNetDriver CDO ConnectionTimeout to 600 BEFORE OpenLevel constructs
    -- the listen GameNetDriver, so the new driver inherits 600 (not the default 60).
    applyNetTuning()
    local world = resolveWorld()
    local gi = FindFirstOf("GameInstance")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- AGameSession::InitOptions consumes MaxPlayers from the travel URL. The
    -- headless listen host owns one native player seat, so offset the customer
    -- capacity by one while Hearth/A2S continues to advertise only real seats.
    local opts = "listen?Port=" .. tostring(GAME_PORT) .. "?MaxPlayers=" .. tostring(NATIVE_MAX_PLAYERS)
    if hasExistingAutoSave() then
        -- Bellwright's UMistGameClientSubsystem::Play builds this exact suffix
        -- for Continue. Slot 4 is EMistSaveSlot::Auto; TEMP maps to TEMP_auto.sav.
        opts = opts .. '? -SaveFile="TEMP" -SaveSlot=4 -SaveSuffix='
        log("host mode=continue save=TEMP slot=Auto")
    else
        log("host mode=new-game (no existing auto-save)")
    end
    log("=== HOST: OpenLevel(" .. tostring(world) .. ", " .. opts .. ") ===")
    local ok, err = pcall(function() gs:OpenLevel(gi, FName(world), true, opts) end)
    log("OpenLevel ok=" .. tostring(ok) .. " err=" .. tostring(err))
end

-- ===========================================================================
-- NATIVE JOINER START DRIVER (v0.18.27)
-- Bellwright's InitNewPlayer hashes the login UniqueNetId/Name, restores or
-- creates AMistOasisPlayerState, and resolves its persistent AMistPlayer actor.
-- Its HandleStartingNewPlayer override possesses that actor only after the
-- asynchronous persistence reference is ready. A first PostLogin call can be
-- early, so retry that native handler from the game thread while the controller
-- remains pawnless. Never force RestartPlayer: it creates a default Player_C
-- disconnected from Bellwright's player state, quests, inventory, interactions,
-- name, and customization.
-- ===========================================================================

-- Per-PlayerController native-start state, keyed by the PC's full-name string.
local joinerState = {}   -- key -> { tries, lastTryT, done, mmTicks, mutableBuild }
local PLAYER_MUTABLE_TEXTURE_CAP = 256
local MUTABLE_SUPPRESSED_TEXTURE_CAP = 64
local NATIVE_START_RETRY_GRACE_SECONDS = 60

-- Resolve the REAL (non-CDO) GameMode instance. Calling RestartPlayer on the
-- Default__ CDO can AV/hang, so never return it.
local function liveGameMode()
    local gms = FindAllOf("GameModeBase") or {}
    for i = 1, #gms do
        local g = gms[i]
        if g and g:IsValid() then
            local gn = "?"; pcall(function() gn = g:GetFullName() end)
            if not string.find(tostring(gn), "Default__") then return g end
        end
    end
    return nil
end

local knownHostControllerNames = {}

-- Is this PlayerController a REMOTE joiner candidate (not the host's own local
-- player)? This is only a first-pass classifier: serviceJoiners must still prove
-- a live NetConnection + stable login identity before spawning or possessing it.
local function isRemoteJoinerCandidate(pc)
    local full = objFullName(pc)
    if knownHostControllerNames[full] then return false end
    local isLocal = false
    pcall(function() isLocal = pc:IsLocalPlayerController() end)
    if isLocal then return false end
    return true
end

local function objectAddress(obj)
    local addr = 0
    pcall(function() addr = obj:GetAddress() end)
    return tonumber(addr) or 0
end

local function playerStateOf(pc)
    local ps = readOptionalField(pc, "PlayerState")
    if ps and ps.IsValid and ps:IsValid() then return ps end
    return nil
end

local function pawnOf(pc)
    local pawn = readOptionalField(pc, "Pawn")
    if pawn and pawn.IsValid and pawn:IsValid() then return pawn end
    pcall(function() pawn = pc:K2_GetPawn() end)
    if pawn and pawn.IsValid and pawn:IsValid() then return pawn end
    return nil
end

local function stringValue(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
    local s = nil
    if pcall(function() s = v:ToString() end) and s ~= nil then return tostring(s) end
    local g = nil
    if pcall(function() g = v:get() end) and g ~= nil then
        if type(g) == "string" then return g end
        s = nil
        if pcall(function() s = g:ToString() end) and s ~= nil then return tostring(s) end
        return tostring(g)
    end
    return tostring(v)
end

local function readPlayerName(ps)
    if not (ps and ps.IsValid and ps:IsValid()) then return "" end
    local nm = nil
    pcall(function() nm = ps:GetPlayerName() end)
    return stringValue(nm)
end

local function callMethod(obj, method, ...)
    if not (obj and obj.IsValid and obj:IsValid()) then return false end
    local fn, exists = readOptionalField(obj, method)
    if not exists then return false end
    if type(fn) ~= "function" and type(fn) ~= "userdata" then return false end
    local args = { ... }
    local unpackArgs = table.unpack or unpack
    return pcall(function() return fn(obj, unpackArgs(args)) end) and true or false
end

-- HOST PHANTOM SANITIZER: the listen host's own local PlayerController can leave
-- a visible/interactive pawn at the starter area. Do not mutate the host
-- PlayerState or name here; that wedged the UE4SS service loop on customer saves.
-- Only hide/isolate the local host controller + pawn from normal gameplay.
local hostSanitized = {}
local hostControllerSanitized = {}

local function sanitizeHostObject(obj, label, hide)
    local addr = objectAddress(obj)
    if addr == 0 or hostSanitized[addr] then return end
    hostSanitized[addr] = true
    local ops = {}
    if callMethod(obj, "SetReplicates", false) then table.insert(ops, "SetReplicates(false)") end
    if set_prop(obj, "bOnlyRelevantToOwner", true) then table.insert(ops, "bOnlyRelevantToOwner=true") end
    if set_prop(obj, "bAlwaysRelevant", false) then table.insert(ops, "bAlwaysRelevant=false") end
    if hide then
        if callMethod(obj, "SetActorHiddenInGame", true) then table.insert(ops, "SetActorHiddenInGame(true)") end
        if callMethod(obj, "SetActorEnableCollision", false) then table.insert(ops, "SetActorEnableCollision(false)") end
        if callMethod(obj, "SetActorTickEnabled", false) then table.insert(ops, "SetActorTickEnabled(false)") end
        if set_prop(obj, "bCanBeDamaged", false) then table.insert(ops, "bCanBeDamaged=false") end
    end
    log("host phantom sanitized " .. tostring(label) .. " ops=" .. table.concat(ops, ",") .. " obj=" .. objFullName(obj))
end

local function sanitizeHost(pc)
    if type(ExecuteInGameThread) ~= "function" then return end
    knownHostControllerNames[objFullName(pc)] = true
    local pcAddr = objectAddress(pc)
    if pcAddr == 0 or hostControllerSanitized[pcAddr] == "complete" then return end
    executeInGameThreadSafe("sanitize-host", function()
        if not (pc and pc.IsValid and pc:IsValid()) then return end
        sanitizeHostObject(pc, "Controller", true)
        local pawn = pawnOf(pc)
        if pawn then
            sanitizeHostObject(pawn, "Pawn", true)
            hostControllerSanitized[pcAddr] = "complete"
        elseif hostControllerSanitized[pcAddr] ~= "waiting-pawn" then
            hostControllerSanitized[pcAddr] = "waiting-pawn"
            log("host phantom controller isolated pc=" .. tostring(pcAddr) .. " waiting for pawn (PlayerState untouched)")
        end
    end)
end

-- HOST NAME JANITOR (ported from Lantern g2_sshost): OSS=Null can revert the
-- joiner's ServerChangeName value to OfflineUser/empty. Capture the last clean
-- name and re-assert it authoritatively from the host via SetPlayerName plus
-- PlayerNamePrivate when the game re-stamps a placeholder.
local cleanNameByPc = {}
local nameSettledByPc = {}
local stableIdByPc = {}
local stableSeedByPc = {}
local rosterNameByPc = {}
local identitySeedLoggedByPc = {}
local identitySkipLoggedByPc = {}

local function trimString(s)
    if type(s) ~= "string" then return nil end
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function isUnrealObjectString(n)
    if type(n) ~= "string" then return false end
    n = trimString(n) or ""
    if n == "" then return false end
    local prefix = n:match("^([%w_]+):")
    if prefix then
        local p = prefix:lower()
        if p:sub(1, 1) == "u"
            or p:find("object", 1, true)
            or p:find("struct", 1, true)
            or p:find("class", 1, true)
            or p:find("function", 1, true)
            or p:find("property", 1, true)
            or p:find("package", 1, true) then
            return true
        end
    end
    return false
end

local function isGeneratedName(n)
    if type(n) ~= "string" then return false end
    n = trimString(n) or ""
    if n == "" or n == "OfflineUser" or n == "Player" or n == "Hearth" or n == "Bellwright" then return true end
    if n == "ERROR, BAD UNIQUE NET ID" or n == "TESTING UID" then return true end
    if n:find("...", 1, true) then return true end
    if isUnrealObjectString(n) then return true end
    if n:match("^DESKTOP%-[A-Z0-9%-]+$") then return true end
    if n:match("^[A-Z0-9_%-]+%-PC%-[0-9A-Fa-f]+$") then return true end
    local prefix, suffix = n:match("^([%w_%-]+)%-([0-9A-Fa-f]+)$")
    if suffix and #suffix >= 8 then
        if prefix == "server" then return true end
        if prefix:match("^[A-Z0-9_%-]+$") then return true end
    end
    return false
end

local function isCarrierName(n)
    return type(n) == "string" and (n:sub(1, 3) == "LK_" or n:sub(1, 3) == "HK_")
end

local function carrierDisplayName(n)
    if not isCarrierName(n) then return nil end
    local carried = n:match("^[LH]K_[^|]*|(.+)$")
    if carried then carried = carried:gsub("^%s+", ""):gsub("%s+$", "") end
    if carried and #carried > 0 then return carried end
    return nil
end

local function setCleanName(ps, name)
    local ok = false
    if pcall(function() ps:SetPlayerName(name) end) then ok = true end
    if set_prop(ps, "PlayerNamePrivate", name) then ok = true end
    callMethod(ps, "OnRep_PlayerName")
    return ok
end

local function enforceCleanName(pc)
    if type(ExecuteInGameThread) ~= "function" then return end
    executeInGameThreadSafe("enforce-clean-name", function()
        if not (pc and pc.IsValid and pc:IsValid()) then return end
        local ps = playerStateOf(pc)
        if not ps then return end
        local key = objectAddress(pc)
        if key == 0 then return end
        local nm = readPlayerName(ps)
        if isCarrierName(nm) then
            local carried = carrierDisplayName(nm)
            if carried and not isGeneratedName(carried) then
                cleanNameByPc[key] = carried
                nameSettledByPc[key] = false
                log("name: captured carrier display name '" .. carried .. "' pc=" .. tostring(key))
            end
            return
        end
        if type(nm) == "string" and #nm > 0 and #nm <= 64 and not isGeneratedName(nm) then
            if cleanNameByPc[key] ~= nm then
                cleanNameByPc[key] = nm
                nameSettledByPc[key] = false
                log("name: captured clean display name '" .. nm .. "' pc=" .. tostring(key))
            end
        end
        local want = cleanNameByPc[key]
        if not want or want == "" then return end
        if nm == want then
            if not nameSettledByPc[key] then
                nameSettledByPc[key] = true
                log("name: '" .. want .. "' is set and holding pc=" .. tostring(key))
            end
            return
        end
        if setCleanName(ps, want) then
            nameSettledByPc[key] = false
            log("name: re-applied display name '" .. want .. "' (was '" .. tostring(nm) .. "') pc=" .. tostring(key))
        end
    end)
end

-- ROSTER REPORT (ported from Lantern g2_sshost): write roster.json next to
-- HearthServer.exe, built only from live IpNetDriver.ClientConnections with an
-- OwningActor + PlayerState. The listen host's local player is never in this
-- array, so the phantom host is excluded by construction.
local ROSTER_PATH = nil
local LOGIN_IDENTITIES_PATH = nil
do
    local sd = os.getenv("HEARTH_SERVER_DIR")
    if not (sd and #sd > 0) then
        local root = LOG:match("^(.*)[\\/][Ll]ogs[\\/][^\\/]+$")
        if root and #root > 0 then sd = root .. "\\HearthServer" end
    end
    if sd and #sd > 0 then
        ROSTER_PATH = sd .. "\\roster.json"
        LOGIN_IDENTITIES_PATH = sd .. "\\login-identities.tsv"
    end
    log("roster: path=" .. tostring(ROSTER_PATH))
    log("login identities: path=" .. tostring(LOGIN_IDENTITIES_PATH))
end

local function jsonEscape(s)
    return (tostring(s):gsub('[%z\1-\31"\\]', function(c)
        local m = { ['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t', ['\b']='\\b', ['\f']='\\f' }
        return m[c] or string.format('\\u%04x', string.byte(c))
    end))
end

local function readStringProp(obj, propName)
    local v, exists = readOptionalField(obj, propName)
    if not exists then return nil end
    local s = stringValue(v)
    if s and s ~= "" and s ~= "nil" then return s end
    return nil
end

local function usableStableId(s)
    if type(s) ~= "string" then return nil end
    s = trimString(s) or ""
    if s == "" or s == "nil" or s == "None" then return nil end
    if isGeneratedName(s) then return nil end
    if isUnrealObjectString(s) then return nil end
    if s:find("...", 1, true) then return nil end
    return s
end

local function usableIdentitySeed(s, allowGenerated)
    if type(s) ~= "string" then return nil end
    s = trimString(s) or ""
    if s == "" or s == "nil" or s == "None" then return nil end
    if s:find("...", 1, true) then return nil end
    if isUnrealObjectString(s) then return nil end
    if (not allowGenerated) and isGeneratedName(s) then return nil end
    return s
end

local function urlDecode(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return s
end

local function queryValue(url, key)
    if type(url) ~= "string" or url == "" then return nil end
    local escKey = key:gsub("([^%w])", "%%%1")
    local v = url:match("[?&]" .. escKey .. "=([^?&%s]+)")
    if not v or v == "" then return nil end
    return urlDecode(v)
end

function ADMIN_AUTH.urlForLog(url)
    local safe = tostring(url or "")
    safe = safe:gsub("([?&]HearthKey=)[^?&%s]+", "%1<redacted>")
    safe = safe:gsub("([?&]HearthAdminTicket=)[^?&%s]+", "%1<redacted>")
    return safe
end

local function stableSeedFromPlayerId(s)
    local id = usableStableId(s)
    if not id then return nil end
    if id:match("^%d+$") and #id >= 15 and #id <= 20 then
        return "steam_" .. id
    end
    return id:gsub("[^%w_%-]", "_")
end

local function connForPc(pc)
    local pcAddr = objectAddress(pc)
    if pcAddr == 0 then return nil end
    for _, nd in ipairs(FindAllOf("IpNetDriver") or {}) do
        local arr = readOptionalField(nd, "ClientConnections")
        if arr then
            local n = safeArrayNum(arr)
            for i = 1, n do
                local conn = arr[i]
                local owner = readOptionalField(conn, "OwningActor")
                if owner and owner.IsValid and owner:IsValid() and objectAddress(owner) == pcAddr then
                    return conn
                end
            end
        end
    end
    return nil
end

local REMOTE_IDENTITY_WAIT_SECONDS = 8
local REMOTE_LOGIN_IDENTITY_WAIT_SECONDS = 165
local pendingRemoteByPc = {}
local remoteWaitLoggedByPc = {}
local remoteQuarantinedByPc = {}
local requestUrlProbeLogged = false

local function usefulRequestUrl(s)
    if type(s) ~= "string" then return nil end
    s = trimString(s) or ""
    if s == "" or s == "nil" or s == "None" then return nil end
    if isUnrealObjectString(s) then return nil end
    if s:find("PlayerId=", 1, true)
        or s:find("PlatformUserId=", 1, true)
        or s:find("HearthDisplayName=", 1, true)
        or s:find("Name=", 1, true)
        or s:find("?", 1, true) then
        return s
    end
    return nil
end

local function requestUrlForConn(conn)
    if not (conn and conn.IsValid and conn:IsValid()) then return "" end
    local results = {}
    local v = readOptionalField(conn, "RequestURL")
    results.direct = stringValue(v)
    v = nil
    pcall(function() v = conn:GetPropertyValue("RequestURL") end)
    results.getprop = stringValue(v)
    results.url = readStringProp(conn, "URL") or ""
    local opStr = nil
    pcall(function()
        local u = readOptionalField(conn, "URL")
        if u then
            local op = readOptionalField(u, "Op")
            if op and op.GetArrayNum then
                local n = safeArrayNum(op)
                local parts = {}
                for i = 1, n do
                    local e = nil
                    pcall(function() e = op[i] end)
                    local es = stringValue(e)
                    if es and es ~= "" and es ~= "nil" and not isUnrealObjectString(es) then
                        table.insert(parts, es)
                    end
                end
                if #parts > 0 then opStr = table.concat(parts, "?") end
            end
        end
    end)
    results.urlop = opStr or ""

    if not requestUrlProbeLogged then
        requestUrlProbeLogged = true
        log("identity urlprobe: direct=" .. ADMIN_AUTH.urlForLog(results.direct)
            .. " getprop=" .. ADMIN_AUTH.urlForLog(results.getprop)
            .. " url=" .. ADMIN_AUTH.urlForLog(results.url)
            .. " urlop=" .. ADMIN_AUTH.urlForLog(results.urlop))
    end

    for _, key in ipairs({ "direct", "getprop", "urlop", "url" }) do
        local s = usefulRequestUrl(results[key])
        if s then return s end
    end
    for _, key in ipairs({ "direct", "getprop", "urlop", "url" }) do
        local s = trimString(results[key])
        if s and s ~= "" and s ~= "nil" and not isUnrealObjectString(s) then return s end
    end
    return ""
end

local function cleanRemoteAddress(s)
    if type(s) ~= "string" then return nil end
    s = trimString(s) or ""
    if s == "" or s == "nil" or s == "None" then return nil end
    if isUnrealObjectString(s) then return nil end
    return s
end

local function remoteAddressForConn(conn)
    if not (conn and conn.IsValid and conn:IsValid()) then return nil end
    local s = nil
    pcall(function() s = conn:LowLevelGetRemoteAddress(true) end)
    s = cleanRemoteAddress(stringValue(s))
    if s then return s end
    s = nil
    pcall(function() s = conn:LowLevelGetRemoteAddress(false) end)
    s = cleanRemoteAddress(stringValue(s))
    if s then return s end
    for _, prop in ipairs({ "RemoteAddress", "RemoteAddr", "PeerAddress", "URL" }) do
        s = cleanRemoteAddress(readStringProp(conn, prop))
        if s then return s end
    end
    return nil
end

local loginIdentityCache = { loadedAt = 0, byAddress = {}, byLogin = {}, rows = {} }

-- v0.18.23: recency-claim registry. When neither the remote address nor the
-- request URL is readable through UE4SS, an unmatched live conn claims the
-- oldest unclaimed fresh TSV row; each row is handed out to exactly one conn.
local LOGIN_ROW_CLAIM_MAX_AGE_MS = 150000
local claimedLoginRows = {}   -- rowKey -> conn object address
local loginRowClaimByConn = {} -- conn object address -> rowKey

local function loginCacheDecode(s)
    return urlDecode(s or "") or ""
end

local function loginRowKey(entry)
    return tostring(entry.ts or 0) .. "|" .. tostring(entry.uid or "") .. "|" .. tostring(entry.seed or "")
end

local function readLoginIdentityCache()
    local now = os.time()
    if loginIdentityCache.loadedAt and (now - loginIdentityCache.loadedAt) < 1 then
        return loginIdentityCache
    end

    local cache = { loadedAt = now, byAddress = {}, byLogin = {}, rows = {} }
    if LOGIN_IDENTITIES_PATH then
        local f = io.open(LOGIN_IDENTITIES_PATH, "r")
        if f then
            for line in f:lines() do
                local cols = {}
                for part in (line .. "\t"):gmatch("(.-)\t") do
                    table.insert(cols, part)
                end
                local rawTs = tostring(cols[1] or ""):gsub("^\239\187\191", "")
                local entry = {
                    ts = tonumber(rawTs) or 0,
                    address = loginCacheDecode(cols[2]),
                    uid = loginCacheDecode(cols[3]),
                    seed = loginCacheDecode(cols[4]),
                    display = loginCacheDecode(cols[5]),
                    loginName = loginCacheDecode(cols[6]),
                    adminTicket = loginCacheDecode(cols[7]),
                }
                if entry.seed ~= "" then
                    table.insert(cache.rows, entry)
                end
                if entry.address ~= "" and entry.seed ~= "" then
                    cache.byAddress[entry.address] = entry
                end
                if entry.loginName ~= "" and entry.seed ~= "" then
                    cache.byLogin[entry.loginName] = entry
                end
            end
            f:close()
        end
    end
    table.sort(cache.rows, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
    loginIdentityCache = cache
    return cache
end

local function claimLoginRowForConn(conn, cache)
    local connKey = objectAddress(conn)
    if connKey == 0 then return nil, nil end

    -- sticky: a conn that already claimed a row keeps it while the row lives
    local claimedKey = loginRowClaimByConn[connKey]
    if claimedKey then
        for _, row in ipairs(cache.rows) do
            if loginRowKey(row) == claimedKey then return row, "claimed-row" end
        end
    end

    local nowMs = os.time() * 1000
    for _, row in ipairs(cache.rows) do -- oldest first: login order ~= service order
        if (row.ts or 0) > 0 and (nowMs - row.ts) <= LOGIN_ROW_CLAIM_MAX_AGE_MS then
            local key = loginRowKey(row)
            if not claimedLoginRows[key] then
                claimedLoginRows[key] = connKey
                loginRowClaimByConn[connKey] = key
                local ageS = math.floor((nowMs - row.ts) / 1000)
                log("identity: recency-claimed login row seed='" .. tostring(row.seed)
                    .. "' display='" .. tostring(row.display) .. "' age=" .. tostring(ageS) .. "s conn=" .. tostring(connKey))
                return row, "recent-row:" .. tostring(ageS) .. "s"
            end
        end
    end
    return nil, nil
end

local function cacheEntryForConn(conn, loginName)
    local cache = readLoginIdentityCache()
    local addr = remoteAddressForConn(conn)
    if addr then
        local entry = cache.byAddress[addr]
        if entry then return entry, "address:" .. addr end
        if not addr:find(":", 1, true) then
            local prefix = addr:gsub("([^%w])", "%%%1")
            for cachedAddr, cachedEntry in pairs(cache.byAddress) do
                if cachedAddr:match("^" .. prefix .. ":") then return cachedEntry, "address-prefix:" .. addr end
            end
        end
    end
    if loginName and loginName ~= "" then
        local entry = cache.byLogin[loginName]
        if entry then return entry, "login:" .. loginName end
    end
    -- v0.18.23: both direct lookups blind (proxy address/URL) or stale-address
    -- rows — fall back to claiming the oldest unclaimed fresh row by recency.
    local claimed, claimSource = claimLoginRowForConn(conn, cache)
    if claimed then return claimed, "claim:" .. tostring(claimSource) end
    return nil, addr and ("miss-address:" .. addr) or "miss-no-address"
end

local function loginIdentityForConn(conn)
    local requestUrl = requestUrlForConn(conn)
    local requestPlayerId = stableSeedFromPlayerId(queryValue(requestUrl, "PlayerId"))
        or stableSeedFromPlayerId(queryValue(requestUrl, "PlatformUserId"))
    local requestDisplay = usableIdentitySeed(queryValue(requestUrl, "HearthDisplayName"), false)
    local loginName = usableIdentitySeed(queryValue(requestUrl, "Name"), true)
    local cached, cacheSource = cacheEntryForConn(conn, loginName)
    local cacheSeed = cached and usableIdentitySeed(cached.seed, true) or nil
    local seed = requestPlayerId or cacheSeed or loginName
    local uid = requestPlayerId or (cached and usableStableId(cached.uid)) or nil
    local display = requestDisplay or (cached and usableIdentitySeed(cached.display, false)) or nil

    if not uid and seed and seed ~= "" then uid = "bw:" .. seed end
    if not display or display == "" then
        if loginName and not isGeneratedName(loginName) then display = loginName
        else display = "Player" end
    end
    local source = requestPlayerId and "request-playerid" or (cacheSeed and ("cache:" .. tostring(cacheSource)) or (loginName and "request-name" or tostring(cacheSource)))
    return uid, seed, display, requestUrl, source
end

local function loginSeedForConn(conn)
    local _, seed = loginIdentityForConn(conn)
    return seed
end

local function remoteIdentityReady(pc, conn)
    local key = objectAddress(pc)
    if key == 0 then return false, nil end
    if stableSeedByPc[key] and stableSeedByPc[key] ~= "" then return true, stableSeedByPc[key] end
    local seed = loginSeedForConn(conn)
    if seed and seed ~= "" then return true, seed end
    return false, nil
end

local SESSION_STR_FIELDS = {
    "PlayerNamePrivate", "PlayerName", "DisplayName", "PlayerDisplayName", "CharacterName", "SessionName",
    "UniqueId", "UniqueIdString", "UniqueID", "UniquePlayerID", "PlayerId", "PlayerIdString",
    "OnlinePlatformName", "PlayerOnlinePlatformName", "SavedNetworkAddress", "PlatformUserId",
    "Nickname", "PlayerNickname", "ProfileName", "AccountName",
}

local function clearUnrealObjectIdentityStrings(obj)
    if not (obj and obj.IsValid and obj:IsValid()) then return 0 end
    local cleared = 0
    for _, prop in ipairs(SESSION_STR_FIELDS) do
        local value = readStringProp(obj, prop)
        if isUnrealObjectString(value) and set_prop(obj, prop, "") then
            cleared = cleared + 1
        end
    end
    return cleared
end

local function hideNonPlayerObject(obj, label, reason)
    if not (obj and obj.IsValid and obj:IsValid()) then return end
    local ops = {}
    if callMethod(obj, "SetReplicates", false) then table.insert(ops, "SetReplicates(false)") end
    if set_prop(obj, "bOnlyRelevantToOwner", true) then table.insert(ops, "bOnlyRelevantToOwner=true") end
    if set_prop(obj, "bAlwaysRelevant", false) then table.insert(ops, "bAlwaysRelevant=false") end
    if callMethod(obj, "SetActorHiddenInGame", true) then table.insert(ops, "SetActorHiddenInGame(true)") end
    if callMethod(obj, "SetActorEnableCollision", false) then table.insert(ops, "SetActorEnableCollision(false)") end
    if callMethod(obj, "SetActorTickEnabled", false) then table.insert(ops, "SetActorTickEnabled(false)") end
    if set_prop(obj, "bCanBeDamaged", false) then table.insert(ops, "bCanBeDamaged=false") end
    log("remote pre-login controller isolated reason=" .. tostring(reason) .. " label=" .. tostring(label) .. " ops=" .. table.concat(ops, ",") .. " obj=" .. objFullName(obj))
end

local function quarantineRemoteController(pc, reason)
    local key = objectAddress(pc)
    if key == 0 or remoteQuarantinedByPc[key] then return end
    remoteQuarantinedByPc[key] = true
    pendingRemoteByPc[key] = nil
    remoteWaitLoggedByPc[key] = nil
    local full = objFullName(pc)
    joinerState[full] = nil
    local cleared = clearUnrealObjectIdentityStrings(pc)
    local ps = playerStateOf(pc)
    if ps then cleared = cleared + clearUnrealObjectIdentityStrings(ps) end
    if type(ExecuteInGameThread) ~= "function" then
        log("remote pre-login quarantine queued without EIGT reason=" .. tostring(reason) .. " pc=" .. full .. " cleared=" .. tostring(cleared))
        return
    end
    executeInGameThreadSafe("quarantine-remote-controller", function()
        if not (pc and pc.IsValid and pc:IsValid()) then return end
        hideNonPlayerObject(pc, "Controller", reason)
        local pawn = pawnOf(pc)
        if pawn then hideNonPlayerObject(pawn, "Pawn", reason) end
        log("remote pre-login controller quarantined reason=" .. tostring(reason) .. " pc=" .. full .. " cleared=" .. tostring(cleared))
    end)
end

local function identityPartsFor(pc, ps)
    local key = objectAddress(pc)
    local conn = connForPc(pc)
    local requestUid, requestSeed, requestDisplay = loginIdentityForConn(conn)

    local currentName = readPlayerName(ps)
    local clean = cleanNameByPc[key]
    local cleanSeed = usableIdentitySeed(clean, false)
    local currentSeed = usableIdentitySeed(currentName, false)
    local seed = requestSeed or cleanSeed or currentSeed

    local uid = requestUid
        or usableStableId(readStringProp(pc, "UniquePlayerID"))
        or usableStableId(readStringProp(ps, "UniqueId"))
        or usableStableId(readStringProp(ps, "UniqueID"))
        or stableSeedFromPlayerId(readStringProp(conn, "PlayerId"))
        or stableSeedFromPlayerId(readStringProp(conn, "UniqueId"))
        or stableSeedFromPlayerId(readStringProp(conn, "PlayerIdString"))

    if not uid and seed and seed ~= "" then uid = "bw:" .. seed end
    if not seed and uid then seed = usableIdentitySeed(uid:gsub("^bw:", ""), true) end
    if not seed or seed == "" then return nil, nil, nil end

    local display = requestDisplay or cleanSeed
    if not display or display == "" then
        if currentSeed and not isCarrierName(currentSeed) then display = currentSeed
        else display = "Player" end
    end
    return uid or ("bw:" .. seed), seed, display
end

local function seedJoinerIdentity(pc, reason)
    local ps = playerStateOf(pc)
    if not ps then return nil end
    local key = objectAddress(pc)
    if key == 0 then return nil end
    local uid, seed, display = identityPartsFor(pc, ps)
    if not seed or seed == "" then
        if not identitySkipLoggedByPc[key] then
            identitySkipLoggedByPc[key] = true
            log("identity: no stable login identity yet; native fields preserved reason=" .. tostring(reason))
        end
        return nil
    end

    stableIdByPc[key] = uid
    stableSeedByPc[key] = seed
    rosterNameByPc[key] = display

    if not identitySeedLoggedByPc[key] then
        identitySeedLoggedByPc[key] = true
        log("identity: captured joiner uid='" .. tostring(uid) .. "' seed='" .. tostring(seed) .. "' display='" .. tostring(display) .. "' reason=" .. tostring(reason)
            .. " (native PlayerState/controller/connection fields preserved)")
    end
    return uid
end

function ADMIN_AUTH.steam64FromIdentity(value)
    value = trimString(tostring(value or "")) or ""
    local candidate = value:match("^steam_(%d+)$") or value:match("^(%d+)$")
    if candidate and #candidate == 17 and candidate:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then
        return candidate
    end
    return nil
end

function ADMIN_AUTH.normalizedRemoteIp(value)
    value = trimString(tostring(value or "")) or ""
    value = value:lower()
    local ipv4 = value:match("^(%d+%.%d+%.%d+%.%d+):%d+$")
        or value:match("^::ffff:(%d+%.%d+%.%d+%.%d+):%d+$")
        or value:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
    if ipv4 then return ipv4 end
    local bracketed = value:match("^%[([^%]]+)%]:%d+$")
    if bracketed then return bracketed end
    if value:match("^%d+%.%d+%.%d+%.%d+$") then return value end
    if value:find(":", 1, true) and value:match("^[0-9a-f:]+$") then return value end
    return nil
end

function ADMIN_AUTH.consumeTicket(pc, steam64)
    if not ADMIN_AUTH.ticketFile or ADMIN_AUTH.ticketFile == "" then return false, "ticket-file-disabled" end
    local conn = connForPc(pc)
    if not conn then return false, "connection-unavailable" end
    local requestUrl = requestUrlForConn(conn)
    local token = queryValue(requestUrl, "HearthAdminTicket")
    local tokenSource = "request-url"
    local cached = cacheEntryForConn(conn, nil)
    local cachedToken = cached and tostring(cached.adminTicket or "") or ""
    if #cachedToken == 64 and cachedToken:match("^[0-9a-f]+$") then
        token = cachedToken
        tokenSource = "validated-login-cache"
    end
    if not token or #token ~= 64 or not token:match("^[0-9a-f]+$") then
        return false, "ticket-missing"
    end
    if ADMIN_AUTH.consumedTickets[token] then return false, "ticket-already-used" end

    local remoteIp = nil
    if tokenSource == "request-url" then
        remoteIp = ADMIN_AUTH.normalizedRemoteIp(remoteAddressForConn(conn))
        if not remoteIp then return false, "remote-address-unavailable" end
    end

    local f = io.open(ADMIN_AUTH.ticketFile, "r")
    if not f then return false, "ticket-registry-unavailable" end
    local now = os.time()
    local matched = false
    for line in f:lines() do
        local fileToken, fileSteam64, expiresText, fileRemoteIp, presented =
            line:match("^([0-9a-f]+)\t([0-9]+)\t([0-9]+)\t([^\t\r\n]+)\t([01])")
        if fileToken == token then
            local expires = tonumber(expiresText) or 0
            matched = fileSteam64 == steam64
                and expires >= now
                and presented == "1"
                and (tokenSource == "validated-login-cache"
                    or ADMIN_AUTH.normalizedRemoteIp(fileRemoteIp) == remoteIp)
            break
        end
    end
    f:close()

    if not matched then return false, "ticket-mismatch-or-expired" end
    ADMIN_AUTH.consumedTickets[token] = true
    return true, tokenSource
end

-- v0.18.43: make the authenticated bIsHostPlayer write actually reach the owning
-- client. Bellwright registers AMistPlayer.bIsHostPlayer as a replicated native
-- property, and this build links Unreal's push-model replication, so writing the
-- value directly leaves it in server memory: the client keeps its default false and
-- the gameplay-settings UI stays locked even though the grant succeeded. This build
-- reflects UNetPushModelHelpers, so mark the exact property dirty and force a net
-- update on the owner. Nothing here authorizes anything — it only publishes a write
-- that ADMIN_AUTH.consumeTicket has already authorized.
local pushModelHelpers = nil
local pushModelHelpersMissing = false

local function markPropertyDirty(obj, propName)
    if pushModelHelpersMissing then return false end
    if not (pushModelHelpers and pushModelHelpers.IsValid and pushModelHelpers:IsValid()) then
        pcall(function()
            pushModelHelpers = StaticFindObject("/Script/Engine.Default__NetPushModelHelpers")
        end)
    end
    if not (pushModelHelpers and pushModelHelpers.IsValid and pushModelHelpers:IsValid()) then
        pushModelHelpersMissing = true
        return false
    end
    return pcall(function() pushModelHelpers:MarkPropertyDirty(obj, FName(propName)) end)
end

local ADMIN_REPUBLISH_PASSES = 8

-- v0.18.45: ForceNetUpdate only flushes dormancy when it can resolve a NetDriver
-- for the actor, so a DORM_Initial pawn silently stays dormant and never sends the
-- property again after its opening bunch. Call FlushNetDormancy explicitly (it is
-- Blueprint-exposed, so UE4SS can reach it) BEFORE ForceNetUpdate, and report the
-- dormancy state so the log says which case we are actually in.
local function replicatePropertyChange(obj, propName)
    local dormancy = optionalFieldText(obj, "NetDormancy")
    local dirty = markPropertyDirty(obj, propName)
    local flushed = pcall(function() obj:FlushNetDormancy() end)
    local forced = pcall(function() obj:ForceNetUpdate() end)
    return dirty, forced, flushed, dormancy
end

function ADMIN_AUTH.grant(pc, pawn)
    if ADMIN_AUTH.count == 0 or type(ExecuteInGameThread) ~= "function" then return end
    local pcKey = objectAddress(pc)
    local pawnKey = objectAddress(pawn)
    if pcKey == 0 or pawnKey == 0 then return end

    local steam64 = ADMIN_AUTH.authorizedSteamByPc[pcKey]
    if not steam64 then
        steam64 = ADMIN_AUTH.steam64FromIdentity(stableIdByPc[pcKey])
            or ADMIN_AUTH.steam64FromIdentity(stableSeedByPc[pcKey])
        if not steam64 or not ADMIN_AUTH.configured[steam64] then return end
        local authorized, reason = ADMIN_AUTH.consumeTicket(pc, steam64)
        if not authorized then
            if not ADMIN_AUTH.deniedByPc[pcKey] then
                ADMIN_AUTH.deniedByPc[pcKey] = true
                log("admin authority denied Steam64=" .. tostring(steam64)
                    .. " reason=" .. tostring(reason))
            end
            return
        end
        ADMIN_AUTH.authorizedSteamByPc[pcKey] = steam64
        log("admin ticket verified Steam64=" .. tostring(steam64)
            .. " source=" .. tostring(reason) .. " pc=" .. tostring(pcKey))
    end
    -- v0.18.45: republish a bounded number of times instead of exactly once.
    -- serviceJoiners calls grant() every 1.5s tick while the joiner holds a pawn,
    -- so ADMIN_REPUBLISH_PASSES covers roughly the first 12 seconds of the session.
    -- A single write lands before the client has finished settling its own pawn on
    -- some joins, and there is no possession hook available on this 5.7.4 build to
    -- time it exactly (engine-thread detours do not fire — see the header notes).
    local republished = ADMIN_AUTH.republishByPc[pcKey] or 0
    -- A different pawn under the same controller means a respawn or a reconnect that
    -- reused the address, so the window restarts rather than inheriting a spent count.
    if ADMIN_AUTH.pawnByPc[pcKey] ~= pawnKey then republished = 0 end
    if ADMIN_AUTH.queuedByPc[pcKey] == pawnKey then return end
    if ADMIN_AUTH.pawnByPc[pcKey] == pawnKey and republished >= ADMIN_REPUBLISH_PASSES then return end

    ADMIN_AUTH.queuedByPc[pcKey] = pawnKey
    local queued = executeInGameThreadSafe("grant-admin-authority", function()
        ADMIN_AUTH.queuedByPc[pcKey] = nil
        if not (pc and pc.IsValid and pc:IsValid() and pawn and pawn.IsValid and pawn:IsValid()) then return end
        local _, exists = readOptionalField(pawn, "bIsHostPlayer")
        if not exists then
            if not ADMIN_AUTH.unavailableByPc[pcKey] then
                ADMIN_AUTH.unavailableByPc[pcKey] = true
                log("admin authority unavailable: pawn has no bIsHostPlayer Steam64=" .. tostring(steam64))
            end
            return
        end
        if set_prop(pawn, "bIsHostPlayer", true) then
            local dirty, forced, flushed, dormancy = replicatePropertyChange(pawn, "bIsHostPlayer")
            -- Read the value back. Every previous log line proved only that the
            -- assignment threw no exception, never that the property actually
            -- holds true on the server, so a locked client could not be told
            -- apart from a failed write.
            local readback = optionalFieldText(pawn, "bIsHostPlayer")
            local pass = republished + 1
            ADMIN_AUTH.pawnByPc[pcKey] = pawnKey
            ADMIN_AUTH.republishByPc[pcKey] = pass
            if pass == 1 or pass >= ADMIN_REPUBLISH_PASSES then
                log("admin authority granted Steam64=" .. tostring(steam64)
                    .. " pc=" .. tostring(pcKey) .. " pawn=" .. tostring(pawnKey)
                    .. " pass=" .. tostring(pass) .. "/" .. tostring(ADMIN_REPUBLISH_PASSES)
                    .. " readback=" .. tostring(readback)
                    .. " dormancy=" .. tostring(dormancy)
                    .. " markdirty=" .. tostring(dirty)
                    .. " flushdormancy=" .. tostring(flushed)
                    .. " forcenetupdate=" .. tostring(forced))
            end
        end
    end, function() ADMIN_AUTH.queuedByPc[pcKey] = nil end)
    if not queued then ADMIN_AUTH.queuedByPc[pcKey] = nil end
end

local function shouldServiceRemoteController(pc, t)
    local key = objectAddress(pc)
    if key == 0 then return false end
    if remoteQuarantinedByPc[key] then return false end
    local conn = connForPc(pc)
    if not (conn and conn.IsValid and conn:IsValid()) then
        local first = pendingRemoteByPc[key]
        if not first then
            pendingRemoteByPc[key] = t
            first = t
        end
        if (t - first) >= REMOTE_IDENTITY_WAIT_SECONDS then
            quarantineRemoteController(pc, "no-live-netconnection")
        elseif not remoteWaitLoggedByPc[key] then
            remoteWaitLoggedByPc[key] = true
            log("remote joiner waiting for live NetConnection pc=" .. objFullName(pc))
        end
        return false
    end

    local ready, seed = remoteIdentityReady(pc, conn)
    if not ready then
        local first = pendingRemoteByPc[key]
        if not first then
            pendingRemoteByPc[key] = t
            first = t
        end
        if (t - first) >= REMOTE_LOGIN_IDENTITY_WAIT_SECONDS then
            quarantineRemoteController(pc, "no-login-identity")
            return false
        end
        if not remoteWaitLoggedByPc[key] then
            remoteWaitLoggedByPc[key] = true
            log("remote joiner waiting for login identity pc=" .. objFullName(pc)
                .. " address='" .. tostring(remoteAddressForConn(conn))
                .. "' request='" .. tostring(requestUrlForConn(conn)) .. "'")
        end
        return false
    end

    local uid = seedJoinerIdentity(pc, "service:" .. tostring(seed))
    if not uid then
        if not remoteWaitLoggedByPc[key] then
            remoteWaitLoggedByPc[key] = true
            log("remote joiner identity seed rejected pc=" .. objFullName(pc) .. " seed='" .. tostring(seed) .. "'")
        end
        return false
    end

    pendingRemoteByPc[key] = nil
    remoteWaitLoggedByPc[key] = nil
    return true
end

local function writeRoster()
    if not ROSTER_PATH then return end
    local players = {}
    local seen = {}
    for _, nd in ipairs(FindAllOf("IpNetDriver") or {}) do
        local arr = readOptionalField(nd, "ClientConnections")
        if arr then
            local n = safeArrayNum(arr)
            for i = 1, n do
                local conn = arr[i]
                local pc = readOptionalField(conn, "OwningActor")
                if pc and pc.IsValid and pc:IsValid() then
                    local ps = playerStateOf(pc)
                    if ps then
                        local key = objectAddress(pc)
                        local nm = readPlayerName(ps)
                        -- A live ClientConnection with an OwningActor PlayerController +
                        -- PlayerState IS a connected player and MUST be counted. The name is
                        -- cosmetic: under OSS=Null the joiner's PlayerState name comes back as
                        -- OfflineUser / a generated machine name, and the old
                        -- `if not isGeneratedName(nm)` gate DROPPED those connections from the
                        -- roster -> A2S reported 0 players even with someone provably in-world
                        -- (the "0 of 4 forever" bug; same class as Cauldron's count fix).
                        -- Prefer the captured clean name; keep a real raw name; only fall back
                        -- to "Player" for empty/generated -- but never drop the connection.
                        if nm == "" or isCarrierName(nm) or isGeneratedName(nm) then
                            nm = rosterNameByPc[key] or cleanNameByPc[key]
                            if not nm or nm == "" then nm = "Player" end
                        end
                        local uid = stableIdByPc[key]
                            or usableStableId(readStringProp(pc, "UniquePlayerID"))
                            or usableStableId(readStringProp(ps, "UniqueId"))
                            or usableStableId(readStringProp(ps, "UniqueID"))
                        if not uid then
                            local seed = usableIdentitySeed(stableSeedByPc[key], true) or usableIdentitySeed(cleanNameByPc[key], false)
                            if seed and seed ~= "" then uid = "bw:" .. seed end
                        end
                        if not uid then uid = "pc:" .. tostring(key) end
                        local dedupe = tostring(key) .. ":" .. tostring(uid)
                        if not seen[dedupe] then
                            seen[dedupe] = true
                            table.insert(players, { uid = uid, name = nm })
                        end
                    end
                end
            end
        end
    end
    local now = math.floor(os.time()) * 1000
    local parts = {}
    for _, p in ipairs(players) do
        table.insert(parts, string.format(
            '{"HearthUserId":"%s","DisplayName":"%s","ConnectedAtUnixMs":%d,"LastPacketUnixMs":%d,"PingMs":0}',
            jsonEscape(p.uid), jsonEscape(p.name), now, now))
    end
    local json = string.format('{"unix_ms":%d,"players":[%s]}', now, table.concat(parts, ","))
    local tmp = ROSTER_PATH .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(json)
        f:close()
        pcall(os.remove, ROSTER_PATH)
        if not os.rename(tmp, ROSTER_PATH) then
            local g = io.open(ROSTER_PATH, "w")
            if g then g:write(json); g:close() end
            pcall(os.remove, tmp)
        end
    end
end

local rosterQueued = false
local function queueRosterWrite()
    if rosterQueued or type(ExecuteInGameThread) ~= "function" then return end
    rosterQueued = true
    local ok = executeInGameThreadSafe("write-roster", function()
        rosterQueued = false
        pcall(writeRoster)
    end, function() rosterQueued = false end)
    if not ok then rosterQueued = false end
end

-- Bellwright's InitNewPlayer creates or restores AMistPlayer asynchronously. Its
-- HandleStartingNewPlayer override possesses that real persistent player once the
-- PlayerState reference is ready. Retry the native handler on a cooldown; never
-- fall back to RestartPlayer, which spawns a disconnected default Player_C.
local function tryStartFor(pc, t)
    local key = tostring(pc:GetFullName())
    local st = joinerState[key]
    if not st then
        st = { tries = 0, lastTryT = -100, firstSeenT = t, done = false }
        joinerState[key] = st
    end
    if st.done then return end

    -- PostLogin already invokes Bellwright's native start handler once. Do not
    -- race its asynchronous persistent-player lookup with an immediate retry:
    -- that can leave an established record temporarily at PlayerCreated and let
    -- the client overwrite it. Only assist after a bounded persistence grace.
    if (t - st.firstSeenT) < NATIVE_START_RETRY_GRACE_SECONDS then
        if not st.persistenceGraceLogged then
            st.persistenceGraceLogged = true
            log("start: waiting " .. tostring(NATIVE_START_RETRY_GRACE_SECONDS)
                .. "s for native persistence before retry key=" .. key)
        end
        return
    end

    -- cooldown 4s between attempts (slow WARP login + spawn). No hard cap: a slow
    -- real join must keep getting attempts until it actually possesses.
    if (t - st.lastTryT) < 4 then return end
    st.lastTryT = t
    st.tries = st.tries + 1

    local gm = liveGameMode()
    if not (gm and gm:IsValid()) then log("start: no live GameMode (try "..st.tries..")"); return end

    -- The native lifecycle handler must run on the game thread.
    local hasEIGT = (type(ExecuteInGameThread) == "function")
    if hasEIGT then
        log("start["..st.tries.."] -> EIGT HandleStartingNewPlayer queued key="..key)
        executeInGameThreadSafe("handle-starting-new-player", function()
            local g = liveGameMode()
            if g and g:IsValid() and pc and pc:IsValid() then
                local seeded = nil
                pcall(function() seeded = seedJoinerIdentity(pc, "pre-native-start") end)
                if not seeded then
                    local f = io.open(LOG, "a")
                    if f then f:write(os.date("%H:%M:%S ").."[bw_host] EIGT HandleStartingNewPlayer SKIPPED: no stable joiner identity\r\n"); f:close() end
                    return
                end
                local ok, err = pcall(function() g:HandleStartingNewPlayer(pc) end)
                local f = io.open(LOG, "a")
                if f then f:write(os.date("%H:%M:%S ").."[bw_host] EIGT HandleStartingNewPlayer EXECUTED ok="..tostring(ok).." err="..tostring(err).."\r\n"); f:close() end
            end
        end)
    else
        log("start["..st.tries.."] WARNING ExecuteInGameThread unavailable -> cannot run native start flow")
    end
end

-- ===========================================================================
-- BENCHMARK SUPPRESSION (v0.6.0) — THE real WARP-host crash fix.
-- Confirmed root cause (UE abslog 2026-06-16): MistBenchmarkSubsystem runs an
-- automated benchmark pass on the listen world; ~58s after Karvenia_08 loads it
-- fires a re-LoadMap of the SAME map ("Pre-load map: .../Karvenia_08") ->
-- UEngine::Browse -> LoadMap -> TrimMemory -> CollectGarbage, and the forced GC
-- chokes routing FinishDestroy to ~69k Texture2D (>10s hard limit) under WARP ->
-- AbortInsideMemberFunction AV. Killing the benchmark loop stops the re-Browse so
-- :12877 stays bound and the host holds indefinitely.
-- Approach: find the MistBenchmarkSubsystem object, one-shot dump its funcs+bools,
-- then every tick call any Stop/Cancel/End/Abort/Finish UFUNCTION and force every
-- "running/active/enabled/auto*" bool to false.
-- ===========================================================================
local benchDumped = false
local benchStopFns = nil   -- discovered stop-style UFUNCTION names
local benchBools = nil      -- discovered gating bool prop names

local function discoverBench(bs)
    benchStopFns = {}
    benchBools = {}
    -- walk class hierarchy collecting candidate function + bool prop names
    local cls = nil; pcall(function() cls = bs:GetClass() end)
    local s = cls; local guard = 0
    while s and s:IsValid() and guard < 8 do
        guard = guard + 1
        pcall(function() s:ForEachFunction(function(fn)
            local fnm = "?"; pcall(function() fnm = fn:GetFName():ToString() end)
            local lf = fnm:lower()
            log("  BENCHFN " .. fnm)
            if lf:find("stop") or lf:find("cancel") or lf:find("abort")
               or lf:find("end") or lf:find("finish") or lf:find("disable") then
                table.insert(benchStopFns, fnm)
            end
        end) end)
        pcall(function() s:ForEachProperty(function(pr)
            local pnm = "?"; pcall(function() pnm = pr:GetFName():ToString() end)
            local tnm = "?"; pcall(function() tnm = pr:GetClass():GetFName():ToString() end)
            log("  BENCHPROP " .. pnm .. " : " .. tnm)
            local lp = pnm:lower()
            if tnm == "BoolProperty" and (lp:find("run") or lp:find("active")
               or lp:find("enable") or lp:find("auto") or lp:find("started")
               or lp:find("pending") or lp:find("benchmark")) then
                table.insert(benchBools, pnm)
            end
        end) end)
        local nxt = nil; pcall(function() nxt = s:GetSuperStruct() end)
        if not (nxt and nxt:IsValid()) then break end
        s = nxt
    end
    log("bench discover: " .. #benchStopFns .. " stopfns, " .. #benchBools .. " bools")
end

-- v0.18.12: cached lookup only. The old full FindAllOf("Object") fallback walked the
-- ENTIRE object array (with per-object class-name reflection) every 1.5s pass when the
-- subsystem was absent — a massive Lua-lock hold for a diagnostic-only probe.
local benchScannedOnce = false
local function findBench()
    local bs = cachedFirst("MistBenchmarkSubsystem")
    if bs and bs:IsValid() then return bs end
    if benchScannedOnce then return nil end
    benchScannedOnce = true
    return nil
end

-- ===========================================================================
-- MATCH-STATE PIN (v0.8.0) — THE real WARP-host crash fix.
-- Confirmed trigger (UE abslog 2026-06-16):
--   Match State Changed WaitingToStart -> InProgress   (host world up)
--   ~48s later: Match State Changed InProgress -> LeavingMap
--   -> UEngine::Browse ".../Karvenia_08?listen?Port=12877" (self server-travel)
--   -> LoadMap -> TrimMemory -> CollectGarbage -> FinishDestroy on ~69k textures
--      exceeds the engine's 10s limit under WARP -> AbortInsideMemberFunction AV.
-- MistOasisGameMode runs a match clock that ends the match (-> LeavingMap ->
-- RestartGame/ServerTravel). We pin AGameMode.MatchState back to "InProgress"
-- every tick so it never reaches LeavingMap, so the self-Browse never fires and
-- :12877 stays bound indefinitely.
-- ===========================================================================
-- one-shot full property dump (name + numeric/name/bool value) for an object,
-- to locate the match-clock / time-limit / idle-timeout that ends the match.
local propDumped = {}
local function dumpProps(obj, tag)
    if not (obj and obj:IsValid()) then return end
    local cls = nil; pcall(function() cls = obj:GetClass() end)
    if not (cls and cls:IsValid()) then return end
    local cname = "?"; pcall(function() cname = cls:GetFName():ToString() end)
    if propDumped[cname] then return end
    propDumped[cname] = true
    log("=== PROPDUMP " .. tag .. " class=" .. cname .. " ===")
    local s = cls; local guard = 0
    while s and s:IsValid() and guard < 8 do
        guard = guard + 1
        pcall(function() s:ForEachProperty(function(pr)
            local pnm = "?"; pcall(function() pnm = pr:GetFName():ToString() end)
            local tnm = "?"; pcall(function() tnm = pr:GetClass():GetFName():ToString() end)
            local val = ""
            pcall(function()
                local v = obj[pnm]
                if type(v) == "number" or type(v) == "boolean" then val = tostring(v)
                elseif tnm == "NameProperty" or tnm == "StrProperty" then val = tostring(v) end
            end)
            log("  P " .. tnm .. " " .. pnm .. " = " .. val)
        end) end)
        local nxt = nil; pcall(function() nxt = s:GetSuperStruct() end)
        if not (nxt and nxt:IsValid()) then break end
        s = nxt
    end
end

local matchPinLogged = false
local function pinMatchState()
    local gm = cachedFirst("GameModeBase")
    if not (gm and gm:IsValid()) then return end
    -- (property dump disabled now that the clock source is identified)
    if not matchPinLogged then
        matchPinLogged = true
    end
    fastPinTick()
end

-- v0.10.0 — the GameMode self-restarts (RestartGame -> non-seamless ServerTravel
-- -> Browse -> LoadMap -> blocking full-GC) ~48s after InProgress. Under WARP the
-- FinishDestroy on ~69k textures blows the engine's 10s limit -> AV. Pinning the
-- state value LOST the race (the Browse fires synchronously in the same frame as
-- SetMatchState). Two structural levers instead:
--   1. bUseSeamlessTravel = true  -> the self-travel takes the SEAMLESS path
--      (transition map + streamed GC), avoiding the blocking LoadMap/TrimMemory
--      full-purge that hits the 10s FinishDestroy abort. Also keeps net conns alive.
--   2. RestartGame UFUNCTION hook (best-effort) to log/neutralize the trigger.
local pinCount = 0
local seamlessSet = false
local transitionMapSet = false
function fastPinTick()
    -- Set a TransitionMap so any server-travel goes the SEAMLESS path (streamed via a
    -- light transition level) instead of a hard UEngine::Browse->LoadMap->blocking
    -- full-GC. Without a transition map, bUseSeamlessTravel is ignored and travel
    -- falls back to hard Browse (the WARP texture-GC crash). Point it at the Menu map.
    if not transitionMapSet then
        pcall(function()
            local ms = StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
            if ms and ms:IsValid() then
                transitionMapSet = writeOptionalField(ms, "TransitionMap", "/Game/Mist/Maps/Menu")
                if transitionMapSet then
                    log("fastpin: TransitionMap -> /Game/Mist/Maps/Menu (seamless travel enabled)")
                end
            end
        end)
    end
    local gm = cachedFirst("GameModeBase")
    if gm and gm:IsValid() then
        -- force seamless travel so any self-restart streams instead of blocking-GC
        pcall(function()
            local seamless, exists = readOptionalField(gm, "bUseSeamlessTravel")
            if exists and seamless ~= true then
                if writeOptionalField(gm, "bUseSeamlessTravel", true) and not seamlessSet then
                    seamlessSet = true
                    log("fastpin: bUseSeamlessTravel -> true")
                end
            end
        end)
        -- (no MatchState pin — the listen server REQUIRES reaching InProgress to bind
        -- the NetDriver; pinning to WaitingToStart prevented :port from ever binding.
        -- The durable fix is hooking/neutralizing the travel source, not the state.)
    end
    -- wipe pending engine/world travel so a late SetMatchState can't be acted on
    local eng = cachedFirst("GameEngine")
    if eng and eng:IsValid() then
        for _, p in ipairs({ "TravelURL", "PendingTravelURL" }) do
            pcall(function()
                local cur = eng[p]
                if cur ~= nil and tostring(cur) ~= "" then eng[p] = "" end
            end)
        end
    end
end

-- One-time UFUNCTION hook BATTERY on every travel-source candidate, to identify
-- exactly what re-Browses the listen map (confirmed: NOT /Script/Engine.GameMode
-- :RestartGame — that hook never fired). Each hook just logs so we learn the path.
local restartHooked = false
local hookTargets = {
    "/Script/Engine.GameMode:RestartGame",
    "/Script/Engine.GameModeBase:ProcessServerTravel",
    "/Script/Engine.GameMode:StartToLeaveMap",
    "/Script/Engine.GameMode:RestartPlayer",
    "/Script/Engine.GameplayStatics:OpenLevel",
    "/Script/Engine.GameplayStatics:OpenLevelBySoftObjectPtr",
    "/Script/Engine.PlayerController:ClientTravel",
    "/Script/Engine.PlayerController:ClientTravelInternal",
    "/Script/Engine.KismetSystemLibrary:ExecuteConsoleCommand",
}
function ensureRestartHook()
    -- DIAGNOSTIC SWEEP DISABLED: confirmed the ~50s re-Browse goes through NO
    -- UFUNCTION (RestartGame/OpenLevel/ClientTravel/ExecuteConsoleCommand hooks
    -- never fired at crash time) -> it is pure native UEngine::Browse, unhookable
    -- from Lua. The durable fix is making the native travel/GC survivable via the
    -- launch-side texture-streaming caps (tiny streaming pool -> few resident
    -- Texture2D RHI resources -> FinishDestroy purge finishes under the 10s limit).
    restartHooked = true
end

local benchStateLogged = false
local function suppressTravel()
    -- PRIMARY: keep the GameMode match in progress so it never self-travels.
    pcall(pinMatchState)
    -- secondary diag (benchmark is idle, kept only for visibility on first sight).
    -- v0.18.12: one-shot — no repeated lookups once logged.
    if benchDumped then return end
    local bs = findBench()
    if not (bs and bs:IsValid()) then return end
    benchDumped = true
    pcall(function()
        local cs = readOptionalField(bs, "CurrentState")
        log("bench idle check: CurrentState=" .. tostring(cs))
    end)
end

-- Flip a freshly possessed character to MOVE_Walking (it comes up MOVE_None on a
-- headless-loaded world). Run on the game thread; idempotent, a few ticks because the
-- CharacterMovement component can re-init right after possess. walktest debug gated
-- behind a marker file (NOT used in production).
local function enableWalk(pawn, key)
    local st = joinerState[key]
    if not st then return end
    if st.mmTicks == nil then st.mmTicks = 0 end
    if st.mmTicks >= 30 then return end
    st.mmTicks = st.mmTicks + 1
    if type(ExecuteInGameThread) ~= "function" then return end
    executeInGameThreadSafe("enable-walk", function()
        local mc = readOptionalField(pawn, "CharacterMovement")
        if mc and mc:IsValid() then pcall(function() mc:SetMovementMode(1, 0) end) end  -- MOVE_Walking
        -- DEBUG self-test only (gated by C:\\Windows\\Temp\\hearth_walktest.marker):
        -- server-authoritative forward walk to PROVE the joiner is a real, collidable,
        -- walkable character. Production never touches this — the customer drives input.
        local walktest = false
        pcall(function() local wf = io.open("C:\\Windows\\Temp\\hearth_walktest.marker", "r"); if wf then wf:close(); walktest = true end end)
        if walktest and mc and mc:IsValid() then
            pcall(function() pawn:AddMovementInput({X=1.0,Y=0.0,Z=0.0}, 1.0, true) end)
            pcall(function() mc:AddInputVector({X=1.0,Y=0.0,Z=0.0}, true) end)
            writeOptionalField(mc, "Velocity", {X=300.0,Y=0.0,Z=0.0})
            pcall(function() pawn:K2_AddActorWorldOffset({X=60.0,Y=0.0,Z=0.0}, true, {}, false) end)
            local loc=nil; pcall(function() loc=pawn:K2_GetActorLocation() end)
            local mm = optionalFieldText(mc, "MovementMode")
            local f=io.open(LOG,"a")
            if f then
                if loc then f:write(os.date("%H:%M:%S ")..string.format("[bw_host] HOSTWALK mode=%s X=%.1f Y=%.1f Z=%.1f\r\n", mm, loc.X, loc.Y, loc.Z))
                else f:write(os.date("%H:%M:%S ").."[bw_host] HOSTWALK noloc\r\n") end
                f:close()
            end
        end
    end)
end

-- ===========================================================================
-- PLAYER MUTABLE HEAD BUILD (v0.18.3) — targeted fix for the headless joiner.
-- The normal Bellwright character-creation path is Mutable-driven:
-- PhotoStage_CreateCharacter / CharacterMannequinIdle initializes a MistMutableComponent,
-- UMistMutableFunctionLibrary::SetRandomParams fills a CO_Human descriptor, then Mutable
-- runs "Update Skeletal Mesh Async" for CO_Human/CO_Human_Female. Our forced net joiner
-- bypasses that character-creation UI and is spawned directly via RestartPlayer, while the
-- host's WARP perf floor keeps Mutable resource generation heavily capped for NPC parties.
-- Result: the survival pawn possesses and walks, but its head/face Mutable output is absent.
--
-- Keep the NPC perf suppression: only when a REMOTE Player_C is possessed, briefly raise the
-- recognized Mutable texture cap, run safe no-arg/scalar update calls on Mutable/customizable
-- objects OWNED BY THAT PAWN, log component proof, then restore the 64px cap. Everything runs
-- through ExecuteInGameThread. No struct-table args are used here.
-- ===========================================================================
local mutableReflectionDumped = false
local normalMutablePathDumped = false
local skeletalMeshAssetName = nil

local function dumpNormalMutablePath()
    if normalMutablePathDumped then return end
    normalMutablePathDumped = true
    if type(ExecuteInGameThread) ~= "function" then return end
    executeInGameThreadSafe("dump-normal-mutable-path", function()
        log("NORMAL-MUTABLE reflection begin: Bellwright head/face builder")
        local total = 0
        for _, clsName in ipairs({ "PhotoStage_CreateCharacter_C", "CharacterMannequinIdle_C", "MistMutableComponent", "CustomizableObjectInstance" }) do
            local emitted = 0
            for _, o in ipairs(safeFindAll(clsName)) do
                if emitted >= 8 then break end
                if o and o:IsValid() then
                    total = total + 1
                    emitted = emitted + 1
                    local owner = "None"; pcall(function() owner = objFullName(o:GetOwner()) end)
                    log("  NORMAL-MUTABLE " .. clsName .. " class=" .. objClassName(o) .. " obj=" .. objFullName(o) .. " owner=" .. owner)
                end
            end
        end
        log("NORMAL-MUTABLE reflection end total=" .. tostring(total) .. " (normal UI path uses PhotoStage/CharacterMannequinIdle + MistMutableComponent; forced RestartPlayer pawn is bridged by PLAYER-MUTABLE)")
    end)
end

local function ownedByPawn(obj, pawn, pawnName)
    if not (obj and obj.IsValid and obj:IsValid() and pawn and pawn.IsValid and pawn:IsValid()) then return false end
    if obj == pawn then return true end
    local owner = nil
    pcall(function() owner = obj:GetOwner() end)
    if owner == pawn then return true end
    local outer = nil
    pcall(function() outer = obj:GetOuter() end)
    if outer == pawn then return true end
    local on = objFullName(obj)
    if pawnName and pawnName ~= "" and string.find(on, pawnName, 1, true) then return true end
    local short = nil
    pcall(function() short = pawn:GetFName():ToString() end)
    if short and short ~= "" and string.find(on, short, 1, true) then return true end
    return false
end

local function readObjProp(obj, propName)
    local v = readOptionalField(obj, propName)
    if v and v.IsValid and v:IsValid() then return v end
    return nil
end

function skeletalMeshAssetName(comp)
    if not (comp and comp.IsValid and comp:IsValid()) then return "None" end
    local mesh = readOptionalField(comp, "SkeletalMesh")
    if not (mesh and mesh.IsValid and mesh:IsValid()) then mesh = readOptionalField(comp, "SkinnedAsset") end
    if not (mesh and mesh.IsValid and mesh:IsValid()) then pcall(function() mesh = comp:GetSkeletalMeshAsset() end) end
    if mesh and mesh.IsValid and mesh:IsValid() then return objFullName(mesh) end
    return "None"
end

local function callMutableNoArg(obj, label, calls)
    if not (obj and obj.IsValid and obj:IsValid()) then return end
    local function record(name, ok, err)
        if ok then table.insert(calls, label .. "." .. name .. "=ok")
        else table.insert(calls, label .. "." .. name .. "=err:" .. tostring(err)) end
    end
    local cn = objClassName(obj)
    local lc = string.lower(cn)
    if string.find(lc, "mistmutable", 1, true) then
        local ok, err = pcall(function() obj:InitializeMutableCustomization() end); record("InitializeMutableCustomization", ok, err)
        ok, err = pcall(function() obj:InitializeMutableCustomization_Internal() end); record("InitializeMutableCustomization_Internal", ok, err)
        ok, err = pcall(function() obj:UpdateMutableCustomization() end); record("UpdateMutableCustomization", ok, err)
        ok, err = pcall(function() obj:RefreshMutableCustomization() end); record("RefreshMutableCustomization", ok, err)
    end
    if string.find(lc, "customizable", 1, true) then
        local ok, err = pcall(function() obj:UpdateSkeletalMeshAsync() end); record("UpdateSkeletalMeshAsync", ok, err)
        ok, err = pcall(function() obj:UpdateSkeletalMeshAsync(true) end); record("UpdateSkeletalMeshAsync(true)", ok, err)
        ok, err = pcall(function() obj:UpdateSkeletalMesh() end); record("UpdateSkeletalMesh", ok, err)
    end
end

local function dumpMutableReflectionOnce(pawn)
    if mutableReflectionDumped then return end
    mutableReflectionDumped = true
    log("PLAYER-MUTABLE normal path from UE log: PhotoStage_CreateCharacter/CharacterMannequinIdle -> UMistMutableComponent::InitializeMutableCustomization_Internal -> UMistMutableFunctionLibrary::SetRandomParams -> Mutable Update Skeletal Mesh Async CO_Human")
    pcall(function()
        local classes = { "MistMutableComponent", "CustomizableObjectInstance", "CustomizableObjectComponent" }
        local emitted = 0
        local dumpedFns = {}
        for _, clsName in ipairs(classes) do
            for _, o in ipairs(safeFindAll(clsName)) do
                if emitted >= 20 then break end
                if o and o:IsValid() then
                    emitted = emitted + 1
                    local line = "PLAYER-MUTABLE REF class=" .. objClassName(o) .. " obj=" .. objFullName(o)
                    log(line)
                    local cls = nil; pcall(function() cls = o:GetClass() end)
                    local actualClass = objClassName(o)
                    if cls and cls:IsValid() and not dumpedFns[actualClass] then
                        dumpedFns[actualClass] = true
                        local found = 0
                        pcall(function()
                            cls:ForEachFunction(function(fn)
                                if found >= 18 then return end
                                local fnm = "?"; pcall(function() fnm = fn:GetFName():ToString() end)
                                local lf = string.lower(tostring(fnm))
                                if string.find(lf, "mutable", 1, true)
                                   or string.find(lf, "custom", 1, true)
                                   or string.find(lf, "skeletal", 1, true)
                                   or string.find(lf, "update", 1, true)
                                   or string.find(lf, "random", 1, true) then
                                    found = found + 1
                                    log("  PLAYER-MUTABLE FN " .. objClassName(o) .. ":" .. tostring(fnm))
                                end
                            end)
                        end)
                    end
                end
            end
        end
        if pawn and pawn:IsValid() then log("PLAYER-MUTABLE target pawn class=" .. objClassName(pawn) .. " obj=" .. objFullName(pawn)) end
    end)
end

local function collectOwnedMutableObjects(pawn)
    local out = {}
    local seen = {}
    local pawnName = objFullName(pawn)
    local function add(obj)
        if obj and obj.IsValid and obj:IsValid() then
            local n = objFullName(obj)
            if not seen[n] then seen[n] = true; table.insert(out, obj) end
        end
    end
    for _, clsName in ipairs({ "MistMutableComponent", "CustomizableObjectComponent", "CustomizableSkeletalComponent", "CustomizableObjectInstance" }) do
        for _, o in ipairs(safeFindAll(clsName)) do
            if ownedByPawn(o, pawn, pawnName) then add(o) end
        end
    end
    local props = {
        "MutableComponent", "MistMutableComponent", "CustomizationComponent", "CustomisationComponent",
        "CustomizableObjectComponent", "CustomizableComponent", "CharacterCustomizationComponent",
        "CustomizableObjectInstance", "MutableInstance", "CustomizableObject"
    }
    for _, p in ipairs(props) do add(readObjProp(pawn, p)) end
    local n = #out
    for i = 1, n do
        for _, p in ipairs({ "CustomizableObjectInstance", "MutableInstance", "Instance", "CustomizableObject", "Component" }) do
            add(readObjProp(out[i], p))
        end
    end
    return out
end

local function playerHeadSnapshot(pawn, key, tag)
    if not (pawn and pawn.IsValid and pawn:IsValid()) then return false, "pawn invalid" end
    local pawnName = objFullName(pawn)
    local headMeshes = 0
    local anyMeshes = 0
    local meshDetails = {}
    for _, comp in ipairs(safeFindAll("SkeletalMeshComponent")) do
        if ownedByPawn(comp, pawn, pawnName) then
            local compName = objFullName(comp)
            local meshName = skeletalMeshAssetName(comp)
            local lower = string.lower(compName)
            local headish = string.find(lower, "head", 1, true) or string.find(lower, "face", 1, true)
                or string.find(lower, "hair", 1, true) or string.find(lower, "beard", 1, true)
                or string.find(lower, "mustache", 1, true) or string.find(lower, "eye", 1, true)
                or string.find(lower, "teeth", 1, true)
            if meshName ~= "None" then anyMeshes = anyMeshes + 1 end
            if headish and meshName ~= "None" then headMeshes = headMeshes + 1 end
            if #meshDetails < 14 and (headish or meshName ~= "None") then
                table.insert(meshDetails, objClassName(comp) .. " " .. compName .. " mesh=" .. meshName)
            end
        end
    end
    local mutableObjects = collectOwnedMutableObjects(pawn)
    local mutableDetails = {}
    for i = 1, #mutableObjects do
        if #mutableDetails >= 10 then break end
        table.insert(mutableDetails, objClassName(mutableObjects[i]) .. " " .. objFullName(mutableObjects[i]))
    end
    local built = headMeshes > 0
    log("PLAYER-MUTABLE SNAPSHOT tag=" .. tostring(tag)
        .. " key=" .. tostring(key)
        .. " pawn=" .. pawnName
        .. " headMeshes=" .. tostring(headMeshes)
        .. " anyMeshes=" .. tostring(anyMeshes)
        .. " mutableOwned=" .. tostring(#mutableObjects)
        .. " built=" .. tostring(built))
    for _, d in ipairs(meshDetails) do log("  PLAYER-MUTABLE MESH " .. d) end
    for _, d in ipairs(mutableDetails) do log("  PLAYER-MUTABLE OBJ " .. d) end
    return built, "headMeshes=" .. tostring(headMeshes) .. " anyMeshes=" .. tostring(anyMeshes) .. " mutableOwned=" .. tostring(#mutableObjects)
end

local function triggerPlayerMutableBuild(pawn, key, tag)
    -- ★ DISABLED 2026-07-02 (join-crash RCA). The native Mutable call storm here
    -- (InitializeMutableCustomization / RefreshMutableCustomization / UpdateSkeletalMeshAsync
    -- on the joiner's components) was the fleet-wide JOIN-TIME CRASH: with the global host
    -- floor suppressing Mutable resource generation (SkipResourceGenerationOnConstruction=1,
    -- EnableSkeletalMeshUpdate=0) those components are constructed WITHOUT their internal
    -- Mutable state, and the native implementations AV on the missing internals
    -- (EXCEPTION_ACCESS_VIOLATION reading 0x63/0x420 — crash-context stacks show the game
    -- thread dying inside the UE4SS Lua->native call nest right after the
    -- "Mutable.MaxTextureSizeToGenerate 256" raise; pcall cannot catch a native AV).
    -- The joiner's head/face generation is owned CLIENT-SIDE by HearthHeadBuild (native
    -- DLL, v0.1.41) — the host never renders the pawn, so host-side mesh generation is
    -- pure risk with no benefit. Keep the one-time reflection dump for telemetry only.
    dumpMutableReflectionOnce(pawn)
    log("PLAYER-MUTABLE TRIGGER tag=" .. tostring(tag) .. " key=" .. tostring(key) .. " skipped (host-side Mutable build disabled; client HearthHeadBuild owns head gen)")
end

local function restoreMutableNpcSuppression(key, reason)
    pcall(function() executeHostConsole("mutable.MaxTextureSizeToGenerate " .. tostring(MUTABLE_SUPPRESSED_TEXTURE_CAP)) end)
    log("PLAYER-MUTABLE restored NPC texture cap=" .. tostring(MUTABLE_SUPPRESSED_TEXTURE_CAP) .. " key=" .. tostring(key) .. " reason=" .. tostring(reason))
end

local function servicePlayerMutableHead(pawn, key, t)
    local st = joinerState[key]
    if not st then return end
    if st.mutableBuild == nil then
        st.mutableBuild = { started = t, lastProbe = -100, triggerTicks = 0, done = false }
        log("PLAYER-MUTABLE start key=" .. tostring(key) .. " prearmed=" .. tostring(st.mutablePrearmed))
    end
    local mb = st.mutableBuild
    if mb.done then return end
    if type(ExecuteInGameThread) ~= "function" then return end
    if mb.triggerTicks < 6 then
        mb.triggerTicks = mb.triggerTicks + 1
        executeInGameThreadSafe("player-mutable-trigger", function()
            if pawn and pawn.IsValid and pawn:IsValid() then
                triggerPlayerMutableBuild(pawn, key, "trigger" .. tostring(mb.triggerTicks))
            end
        end)
    end
    if (t - mb.lastProbe) >= 3 then
        mb.lastProbe = t
        executeInGameThreadSafe("player-mutable-probe", function()
            if not (pawn and pawn.IsValid and pawn:IsValid()) then return end
            local built, summary = playerHeadSnapshot(pawn, key, "probe" .. tostring(mb.triggerTicks))
            if built then
                mb.done = true
                log("PLAYER-MUTABLE BUILT key=" .. tostring(key) .. " " .. tostring(summary))
                restoreMutableNpcSuppression(key, "built")
            elseif (t - mb.started) >= 45 then
                mb.done = true
                log("PLAYER-MUTABLE TIMEOUT key=" .. tostring(key) .. " " .. tostring(summary))
                restoreMutableNpcSuppression(key, "timeout")
            end
        end)
    end
end

-- ===========================================================================
-- LANDING/READY-GATE RELEASE (v0.18.0) — the final possessed-but-black join blocker.
-- A fresh OpenLevel(Karvenia_08, listen) is a NEW GAME: the joiner's character is
-- spawned at the surface PlayerStart (proven on-box: RestartPlayer places Player_C
-- at the starting-area PlayerStart, X=110244 Y=-124073 Z=-34357, MOVE_Walking, ON
-- THE GROUND — the whole map sits at Z~-34k, that's surface, not underground). The
-- "sky descent" the player sees is NOT a positional drop: the pawn is grounded the
-- whole time. It is a PURELY CLIENT-SIDE CAMERA CINEMATIC driven by the controller:
-- OasisPlayerController_C:PlayIntro -> SetCinematicMode(true) sweeps a sky->ground
-- camera and LOCKS OUT player input/movement until IntroStopping ends it. Under the
-- no-GPU WARP host's join-time load the intro crawls, so the customer is stuck mid-
-- descent with no ground control.
--
-- v0.17.0 only cleared the SERVER copy: bPlayerIsWaiting=false, SetCinematicMode(false),
-- IntroStopping(). Real client telemetry proved the CLIENT copy stayed TRUE for 6+ min
-- after possess. The missing part is the owning-client finish/restart path: ClientRestart
-- and ClientSetCinematicMode are NetClient RPCs, while SetCinematicMode/IntroStopping are
-- local calls. So v0.18.0 drives both:
--   1. bPlayerIsWaiting = false              (clear the "waiting for intro/customize" gate)
--   2. ClientRestart(pawn)                    (owning-client restart/OnRep possess finish)
--   3. ClientSetCinematicMode(false, ...)     (owning-client release RPC)
--   4. SetCinematicMode(false, ...)           (server-side mirror, harmless/idempotent)
--   5. IntroStopping()                        (server-side BP mirror, harmless/idempotent)
-- Repeated a few ticks because PlayIntro can fire just AFTER possess (and re-arm
-- cinematic mode); the repeat catches that and re-releases control. Idempotent + safe
-- on a controller that never started the intro (the calls are no-ops then).
-- All on the game thread via ExecuteInGameThread — calling these from the async
-- LoopAsync thread risks the same VM hard-stall as RestartPlayer on this 5.7 build.
local function dumpJoinGateReflection(pc, key)
    local st = joinerState[key]
    if not st or st.joinGateReflectionDumped then return end
    st.joinGateReflectionDumped = true
    local wanted = {
        ClientRestart = true,
        ClientSetCinematicMode = true,
        SetCinematicMode = true,
        ServerAcknowledgePossession = true,
        ServerCheckClientPossession = true,
        ServerCheckClientPossessionReliable = true,
        IntroStopping = true,
        PlayIntro = true,
        ReceivePossess = true,
    }
    pcall(function()
        local cls = pc:GetClass()
        local s = cls
        local guard = 0
        while s and s:IsValid() and guard < 12 do
            guard = guard + 1
            local cname = "?"; pcall(function() cname = s:GetFName():ToString() end)
            pcall(function()
                s:ForEachFunction(function(fn)
                    local fnm = "?"; pcall(function() fnm = fn:GetFName():ToString() end)
                    if wanted[fnm] then
                        local flags = "?"; pcall(function() flags = fn:GetFunctionFlags() end)
                        log("JOIN-GATE FN " .. tostring(cname) .. ":" .. tostring(fnm) .. " flags=" .. flagText(flags))
                    end
                end)
            end)
            pcall(function()
                s:ForEachProperty(function(pr)
                    local pnm = "?"; pcall(function() pnm = pr:GetFName():ToString() end)
                    if pnm == "bPlayerIsWaiting" then
                        local tnm = "?"; pcall(function() tnm = pr:GetClass():GetFName():ToString() end)
                        local off = "?"; pcall(function() off = pr:GetOffset_Internal() end)
                        log("JOIN-GATE PROP " .. tostring(cname) .. ":bPlayerIsWaiting type=" .. tostring(tnm) .. " offset=" .. tostring(off))
                    end
                end)
            end)
            local nxt = nil; pcall(function() nxt = s:GetSuperStruct() end)
            if not (nxt and nxt:IsValid()) then break end
            s = nxt
        end
    end)
end

local function skipLandingIntro(pc, key, pawn)
    local st = joinerState[key]
    if not st then return end
    if st.introTicks == nil then st.introTicks = 0 end
    if st.introTicks >= 60 then return end   -- ~60 * 1.5s = 90s window; covers a slow WARP intro/load
    st.introTicks = st.introTicks + 1
    if type(ExecuteInGameThread) ~= "function" then return end
    executeInGameThreadSafe("skip-landing-intro", function()
        if not (pc and pc.IsValid and pc:IsValid()) then return end
        local p = pawn
        if not (p and p.IsValid and p:IsValid()) then p = readOptionalField(pc, "Pawn") end
        dumpJoinGateReflection(pc, key)

        local before = optionalFieldText(pc, "bPlayerIsWaiting")
        local okWait = writeOptionalField(pc, "bPlayerIsWaiting", false)

        -- ClientRestart is the standard owning-client "finish possession/restart" RPC.
        -- Send it for the first few release ticks, then stop to avoid fighting normal play.
        local okRestart = "skip"
        local st2 = joinerState[key]
        if p and p.IsValid and p:IsValid() and st2 then
            if st2.clientRestartTicks == nil then st2.clientRestartTicks = 0 end
            if st2.clientRestartTicks < 8 then
                st2.clientRestartTicks = st2.clientRestartTicks + 1
                local ok = pcall(function() pc:ClientRestart(p) end)
                okRestart = tostring(ok)
            end
        end

        -- ClientSetCinematicMode is the owning-client RPC; SetCinematicMode is only local.
        local okClientCin = pcall(function() pc:ClientSetCinematicMode(false, true, true, true, true) end)
        if not okClientCin then
            okClientCin = pcall(function() pc:ClientSetCinematicMode(false, true, true, true) end)
        end
        local okSetCin = pcall(function() pc:SetCinematicMode(false, false, true, true, true) end)
        local okIntro = pcall(function() pc:IntroStopping() end)
        local after = optionalFieldText(pc, "bPlayerIsWaiting")
        local st2 = joinerState[key]
        if st2 and not st2.introLogged then
            st2.introLogged = true
            local f = io.open(LOG, "a")
            if f then
                f:write(os.date("%H:%M:%S ").."[bw_host] JOIN-GATE RELEASE hostWaiting="..before.."->"..after
                    .." setWait="..tostring(okWait)
                    .." ClientRestart="..tostring(okRestart)
                    .." ClientSetCinematicMode="..tostring(okClientCin)
                    .." SetCinematicMode="..tostring(okSetCin)
                    .." IntroStopping="..tostring(okIntro)
                    .." key="..tostring(key).."\r\n")
                f:close()
            end
        end
    end)
end

local diagT = 0
local lastWorldTime = nil
local lastWorldTimeWall = nil
local function serviceJoiners(t)
    local pcs = FindAllOf("PlayerController") or {}
    diagT = diagT + 1
    local nRemote = 0
    travelSignRemotePlayerCount = 0
    travelSignRemotePlayers = {}
    for i = 1, #pcs do
        local pc = pcs[i]
        if pc and pc:IsValid() then
            if isRemoteJoinerCandidate(pc) then
                if shouldServiceRemoteController(pc, t) then
                    nRemote = nRemote + 1
                    local pawn = pawnOf(pc)
                    local hasPawn = (pawn and pawn:IsValid()) and true or false
                    local key = tostring(pc:GetFullName())
                    if hasPawn then
                        table.insert(travelSignRemotePlayers, objFullName(pawn))
                        ADMIN_AUTH.grant(pc, pawn)
                        local st = joinerState[key]
                        if st and not st.done then
                            st.done = true
                            local pn = "?"; pcall(function() pn = pawn:GetClass():GetFName():ToString() end)
                            log("JOINER POSSESSED pawn=" .. pn .. " pc=" .. key)
                            requestTravelSignPlayerSync("remote-player-possessed")
                            st.mmTicks = 0
                        elseif not st then
                            -- Joiner already completed Bellwright's native start before the
                            -- service loop observed it pawnless.
                            joinerState[key] = { tries = 0, lastTryT = -100, done = true, mmTicks = 0 }
                            log("JOINER POSSESSED (pre-pawned) pc=" .. key)
                            requestTravelSignPlayerSync("remote-player-pre-possessed")
                        end
                    else
                        tryStartFor(pc, t)
                    end
                end
            else
                sanitizeHost(pc)
            end
        end
    end
    travelSignRemotePlayerCount = nRemote
    -- Roster refresh. When a remote joiner is live, rewrite every service tick so
    -- the launcher's player list stays current. When nobody is joined we STILL
    -- refresh on a slow cadence (every ~9s) so a stale entry from a prior session
    -- cannot linger forever: writeRoster only lists live IpNetDriver connections
    -- (and applies the current identity guards), so an idle host writes players:[]
    -- and any "1 player, no name" phantom clears itself. This was the WARP-era
    -- concern (a live UObject scan at 0.65fps), but under -nullrhi (30fps) the
    -- IpNetDriver scan is cheap, so idle refresh is safe. (v0.18.22)
    if nRemote > 0 then
        queueRosterWrite()
    elseif diagT % 6 == 0 then
        queueRosterWrite()
    end
    -- light heartbeat every ~18s, WITH a real engine-tick-rate proof: World.TimeSeconds
    -- advances by the engine's game-time per tick, so (delta WorldTime / delta wallclock)
    -- ~= 1.0 means the engine is keeping real time (healthy sub-second net tick); a ratio
    -- far below 1.0 means the engine is running slow (frames take multiple wall seconds).
    if diagT % 6 == 0 then
        local wt = nil
        pcall(function()
            local w = cachedFirst("World")
            if w and w:IsValid() then
                local raw = readOptionalField(w, "TimeSeconds")
                if type(raw) == "number" then wt = raw end
            end
        end)
        local tickInfo = ""
        if type(wt) == "number" and type(lastWorldTime) == "number" then
            local dwt = wt - lastWorldTime
            local dwall = os.time() - lastWorldTimeWall
            if dwall > 0 then
                tickInfo = string.format(" | TICKRATE worldDt=%.2fs wallDt=%ds ratio=%.2f (1.0=realtime)", dwt, dwall, dwt / dwall)
            end
        end
        if type(wt) == "number" then
            lastWorldTime = wt
            lastWorldTimeWall = os.time()
        end
        log("hb t=" .. t .. " PCs=" .. #pcs .. " remote=" .. nRemote .. tickInfo)
    end
end


-- Settled-menu gate state machine (poll 1.5s).
local t = 0
local lastWorld = nil
local stableCount = 0
local STABLE_NEEDED = 4      -- 4 * 1.5s = 6s of unchanged menu world
local MIN_SETTLE_T = 18      -- never fire before 18s
local fired = false
local fireT = nil
local up = false
local upT = nil
local retries = 0
local MAX_RETRIES = 2
local probeT = 0
local preHostSuppressionQueued = false
local preHostSuppressionT = 0
local postHostGameInstanceMissingLogged = false
local loopHeartbeatT = 0
local serviceJoinersErrorLogged = false
local forceSaveServiceErrorLogged = false
local FORCE_SAVE_MARKER_NAME = "hearth_force_save_" .. tostring(GAME_PORT) .. ".marker"
local FORCE_SAVE_MARKERS = {}
local forceSaveLogDir = type(LOG) == "string" and LOG:match("^(.*)[/\\][^/\\]+$") or nil
if forceSaveLogDir and #forceSaveLogDir > 0 then
    table.insert(FORCE_SAVE_MARKERS, forceSaveLogDir .. "\\" .. FORCE_SAVE_MARKER_NAME)
end
table.insert(FORCE_SAVE_MARKERS, "C:\\Windows\\Temp\\" .. FORCE_SAVE_MARKER_NAME)
local forceSaveQueued = false
local forceSaveLastCheckT = -10

local function isLiveObject(obj)
    if obj == nil then return false end
    local valid = false
    pcall(function() valid = obj:IsValid() end)
    return valid == true
end

local function resolveForcedSaveComponent()
    local component = nil
    pcall(function() component = cachedFirst("MistCheatingComponent") end)
    if isLiveObject(component) then return component end

    for _, candidate in ipairs(safeFindAll("MistCheatingComponent")) do
        if isLiveObject(candidate) then
            objCache["MistCheatingComponent"] = candidate
            return candidate
        end
    end
    return nil
end

local function serviceForcedSave()
    if forceSaveQueued or (t - forceSaveLastCheckT) < 5 then return end
    forceSaveLastCheckT = t
    local markerFound = false
    for _, markerPath in ipairs(FORCE_SAVE_MARKERS) do
        local marker = io.open(markerPath, "r")
        if marker then
            marker:close()
            markerFound = true
            break
        end
    end
    if not markerFound then return end
    if type(ExecuteInGameThread) ~= "function" then
        log("force-save marker pending: ExecuteInGameThread unavailable")
        return
    end

    log("force-save marker detected for gameplay port " .. tostring(GAME_PORT))
    local component = resolveForcedSaveComponent()
    if not component then
        log("force-save marker pending: MistCheatingComponent unavailable")
        return
    end

    forceSaveQueued = true
    local queued = executeInGameThreadSafe("force-save", function()
        log("force-save game-thread callback entered")
        local ok, err = pcall(function()
            component:Save(4, "TEMP") -- EMistSaveSlot::Auto
        end)
        forceSaveQueued = false
        if ok then
            for _, markerPath in ipairs(FORCE_SAVE_MARKERS) do pcall(os.remove, markerPath) end
            log("force-save requested through MistCheatingComponent slot=Auto name=TEMP")
        else
            log("force-save request failed: " .. tostring(err))
        end
    end, function() forceSaveQueued = false end)
    if not queued then
        forceSaveQueued = false
        log("force-save request could not be queued")
    end
end

function GAMEPLAY_SETTINGS.readStatus()
    if not GAMEPLAY_SETTINGS.status or #GAMEPLAY_SETTINGS.status == 0 then return "state=unmanaged" end
    local file = io.open(GAMEPLAY_SETTINGS.status, "r")
    if not file then return "state=missing" end
    local state = nil
    local revision = nil
    local errorCode = nil
    for line in file:lines() do
        line = tostring(line):gsub("[\r\n]+$", "")
        local key, value = line:match("^([a-z_]+)=([a-z0-9_%.%-]+)$")
        if key == "state" then state = value
        elseif key == "revision" then revision = value
        elseif key == "error" then errorCode = value end
    end
    file:close()
    return "state=" .. tostring(state or "invalid")
        .. " revision=" .. tostring(revision or "-")
        .. " error=" .. tostring(errorCode or "-")
end

function GAMEPLAY_SETTINGS.loadNative()
    if GAMEPLAY_SETTINGS.native then return true end
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        log("gameplay settings native unavailable: package.loadlib missing")
        return false
    end
    local dll = ".\\ue4ss\\Mods\\bw_host\\HearthGameplaySettings.dll"
    local ok, service = pcall(package.loadlib, dll, "HearthGameplaySettings_Service")
    if ok and type(service) == "function" then
        GAMEPLAY_SETTINGS.native = service
        log("gameplay settings native loaded path=" .. dll)
        return true
    end
    log("gameplay settings native load failed path=" .. dll .. " err=" .. tostring(service))
    return false
end

function GAMEPLAY_SETTINGS.service()
    if GAMEPLAY_SETTINGS.queued or (t - GAMEPLAY_SETTINGS.lastCheckT) < 5 then return end
    GAMEPLAY_SETTINGS.lastCheckT = t
    if not GAMEPLAY_SETTINGS.loadNative() then return end

    GAMEPLAY_SETTINGS.queued = true
    local queued = executeInGameThreadSafe("gameplay-settings", function()
        GAMEPLAY_SETTINGS.native()
        GAMEPLAY_SETTINGS.queued = false
        local status = GAMEPLAY_SETTINGS.readStatus()
        if status ~= GAMEPLAY_SETTINGS.lastStatus then
            GAMEPLAY_SETTINGS.lastStatus = status
            log("gameplay settings " .. status)
        end
    end, function() GAMEPLAY_SETTINGS.queued = false end)
    if not queued then GAMEPLAY_SETTINGS.queued = false end
end

-- v0.18.50: live-world identity + loop error counter. Scoped in a do-block
-- because the main chunk is at Lua's 200-active-locals limit.
do
local loop50 = { liveWorldName = nil, liveWorldChangeT = -1000, mainLoopErrors = 0 }
loop50.mainLoopBody = function()
    t = t + 1.5
    local gi = nil
    if not postHostGameInstanceMissingLogged then gi = cachedFirst("GameInstance") end
    if not (gi and gi:IsValid()) then
        if not fired then return false end
        if not postHostGameInstanceMissingLogged then
            postHostGameInstanceMissingLogged = true
            log("main loop: GameInstance lookup missing after host fire; continuing from live world/netdriver state")
        end
    end

    local wn = worldName()
    if wn == lastWorld then stableCount = stableCount + 1 else stableCount = 0 end
    lastWorld = wn

    if not fired then
        if t >= MIN_SETTLE_T and stableCount >= STABLE_NEEDED then
            if not preHostSuppressionQueued then
                preHostSuppressionQueued = true
                preHostSuppressionT = t
                log("settled at t=" .. t .. " (menu stable) -> pre-host WARP suppression")
                pcall(applyRenderCvars)
                pcall(disableWorldRendering)
                return false
            end
            if (not renderCvarsEverApplied or not worldRenderDisabledLogged) and (t - preHostSuppressionT) < 6 then
                return false
            end
            if not renderCvarsEverApplied or not worldRenderDisabledLogged then
                log("pre-host WARP suppression not fully confirmed after " .. tostring(t - preHostSuppressionT) .. "s -> host anyway")
            end
            fired = true; fireT = t
            log("settled at t=" .. t .. " (menu stable) -> host")
            pcall(doHost)
        end
    else
        local nd = netDriverValid()
        -- v0.18.50: a ServerTravel (the Halmare voyage) replaces the listen
        -- world. Everything remembered by path belongs to the old world.
        if nd and up and upT and (t - upT) > 30 then
            local wnLive = netWorld and objFullName(netWorld) or nil
            if wnLive and wnLive ~= "None" and loop50.liveWorldName and wnLive ~= loop50.liveWorldName
                and (t - loop50.liveWorldChangeT) >= 60 then
                loop50.liveWorldChangeT = t
                log("live world changed: " .. tostring(loop50.liveWorldName) .. " -> " .. wnLive)
                clearObjCache()
                pcall(function() resetTravelSignDiscovery("world-changed") end)
            end
            if wnLive and wnLive ~= "None" then loop50.liveWorldName = wnLive end
        end
        if nd and not up then
            up = true; upT = t; log("listen server UP (NetDriver valid) t=" .. t)
            -- v0.18.12: the menu world/GameMode died in the OpenLevel transition —
            -- drop all cached refs so the pins re-resolve against the LISTEN world.
            clearObjCache()
            -- the live GameNetDriver now exists -> stamp 600 on the instance + CDO, and verify.
            applyNetTuning()
            log("NETPROOF (host up) " .. reportNetTuning())
            -- collapse WARP render + Mutable sim cost so the game/net thread ticks sub-second
            -- The pre-host/menu application can be reset by OpenLevel(Karvenia_08);
            -- force one fresh pass in the listen world before idle/join validation.
            renderCvarsEverApplied = false
            renderCvarsApplyQueued = false
            applyRenderCvars()
            -- the decisive lever: stop the viewport drawing the world entirely so the game
            -- thread no longer blocks on the WARP render frame (net tick decouples to sub-second)
            disableWorldRendering()
            lastWorldRenderDisableT = t
            -- The normal Mutable-path reflection dump was useful during bring-up, but
            -- it walks live UObject graphs at startup. Leave it disabled in production
            -- so host readiness cannot be wedged by diagnostic reflection.
        end
        hostUp = true   -- start the fast match-pin loop as soon as we've fired the host OpenLevel
        if up then
            loopHeartbeatT = loopHeartbeatT + 1
            if loopHeartbeatT % 6 == 0 then
                log("loop hb t=" .. t .. " service-loop=alive")
            end
        end
        -- defensive: if the world bounced back to menu without a NetDriver, re-arm and retry.
        if not nd and not up and (t - fireT) >= 9 and retries < MAX_RETRIES then
            retries = retries + 1
            log("no NetDriver 9s after fire (bounce) -> retry #" .. retries)
            fired = false; stableCount = 0; preHostSuppressionQueued = false; preHostSuppressionT = 0
        end
        -- once up, EVERY tick: clear any pending world-travel URL so TickWorldTravel
        -- never fires Browse->LoadMap->GC (the WARP texture-GC crash). Crux fix.
        if up and (not upT or (t - upT) <= 12) then
            pcall(suppressTravel)
        end
        -- Once up, service joiners every tick (1.5s). tryStartFor has its own
        -- 4s per-PC cooldown, so persistence gets time to finish between native
        -- HandleStartingNewPlayer attempts.
        if up then
            local discoveryOk, discoveryErr = pcall(function() serviceTravelSignDiscovery(t) end)
            if not discoveryOk then
                log("travel sign discovery service ERROR: " .. tostring(discoveryErr))
            end
            local ok, err = pcall(function() serviceJoiners(t) end)
            if not ok and not serviceJoinersErrorLogged then
                serviceJoinersErrorLogged = true
                log("serviceJoiners ERROR (continuing loop): " .. tostring(err))
            end
            local saveOk, saveErr = pcall(serviceForcedSave)
            if not saveOk and not forceSaveServiceErrorLogged then
                forceSaveServiceErrorLogged = true
                log("force-save service ERROR (request remains pending): " .. tostring(saveErr))
            end
            local settingsOk, settingsErr = pcall(GAMEPLAY_SETTINGS.service)
            if not settingsOk then
                log("gameplay settings service ERROR: " .. tostring(settingsErr))
            end
        end
        -- re-assert the 600s server-side timeouts periodically: config gets wiped and
        -- the GameNetDriver can be (re)constructed after our initial stamp. Cheap, and
        -- it guarantees a freshly-built driver never sits at the default 60s when a real
        -- (WARP-slow) joiner is mid-stream. Every ~12s.
        if up and (math.floor(t) % 12 == 0) then
            pcall(applyNetTuning)
        end
        -- The full cvar batch is expensive on WARP because ExecuteConsoleCommand runs on
        -- the game thread and can serialize with D3D12 work. Queue it once per boot.
        -- Re-assert only the safe viewport lever. Never scan or mutate live Mutable
        -- components: Bellwright may be updating their skeletal meshes asynchronously.
        if up and ((t - lastWorldRenderDisableT) >= WORLD_RENDER_DISABLE_INTERVAL) then
            pcall(disableWorldRendering)
            lastWorldRenderDisableT = t
        end
        if up and (math.floor(t) % 15 == 0) then
            if not renderCvarsEverApplied then pcall(applyRenderCvars) end
        end
    end
    return false
end
-- v0.18.50: a Lua error escaping a LoopAsync body is raised inside UE4SS's
-- async update with no handler and aborts the whole host process (seen
-- 2026-09-05 11:05, luaD_throw -> abort). Nothing may escape.
LoopAsync(1500, function()
    local ok, result = pcall(loop50.mainLoopBody)
    if not ok then
        loop50.mainLoopErrors = loop50.mainLoopErrors + 1
        if loop50.mainLoopErrors <= 20 then
            log("main loop ERROR (continuing): " .. tostring(result))
        end
        return false
    end
    return result and true or false
end)
end

-- Dedicated FAST loop (250ms): once the host is up, aggressively pin MatchState
-- back to InProgress + wipe pending travel. Under WARP the engine ticks are many
-- seconds apart, so this 250ms loop reliably reverts the InProgress->LeavingMap
-- transition BEFORE the next engine tick's TickWorldTravel can act on it -> the
-- self-Browse/LoadMap/GC crash never happens and :12877 stays bound.
LoopAsync(250, function()
    local ok, retire = pcall(function()
        if up and upT and (t - upT) > 12 then
            log("fastpin loop retired after listen startup t=" .. tostring(t))
            return true
        end
        if hostUp then pcall(ensureRestartHook); pcall(fastPinTick) end
        return false
    end)
    if not ok then return false end
    return retire and true or false
end)
