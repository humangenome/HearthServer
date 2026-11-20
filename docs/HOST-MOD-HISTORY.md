# Host mod history

Version notes for the Hearth host mods, newest first. They lived in the comment header of each
mod's `main.lua` until v0.1.102 and moved here so the shipped scripts carry only what the code needs
to be read correctly. The design notes that still matter stay in the headers.

## bw_host (`dist/ue4ss-server/Mods/bw_host/Scripts/main.lua`)

```text
v0.18.71: HEARTH_ADMIN_STEAM_IDS and the Steam identity read take any personal account's SteamID64: 17 ASCII
           digits from 76561197960265729 to 76561202255233023 (ADMIN_AUTH.isSteamId64). Before, an ID had to
           start 7656119, so the newer accounts Steam will hand out from 7656120 could not be admins (2026-11-12).
v0.18.70: comment-only. The version history moved from the header to docs/HOST-MOD-HISTORY.md
           (v0.1.102); the header keeps the design notes the code depends on.
v0.18.69: the first minutes after a start and the background loop, from the 2026-11-15 re-lab of v0.18.68 on
           our test server (start minutes 515-843 ms of game-thread time a minute, 7-9 walks; the background loop
           about 2.5 s a minute with nobody on and 6.2-6.4 s with one player). Travel Signs: a startup scan pass
           is two walks a minute apart (a pass every 2 minutes, still 8 passes), and while it runs the waiting and
           new provider names are checked by its own provider walk instead of walks of their own (a name that walk
           does not list is dropped as gone); after it, at most one provider-check walk per 30 s. Desk harness
           (tests/host-start-minutes.test.lua, calibrated on the lab's 7-9 walks): 1 walk a minute in the start
           minutes, about 110 ms with the other game-thread work. Background loop: a player's connection is found
           on the listen world's own net driver (it walked every object for the net drivers twice per player per
           round), and with no client connection the controllers are walked on heartbeat rounds only (every 9 s,
           not every 1.5 s); HEARTH_BG_QUIET=0 or Logs\bw_bgquiet.off turns that off. While the world is paused
           the safety-net controller walk stays every 10th round, heartbeat round or not (re-lab 2026-11-15 13:30).
           The bw_pause status file is read 512 bytes at most; a longer one means not paused (Security).
v0.18.68: the Travel Sign pass does one piece of work at a time (2026-11-14 re-lab of v0.18.67 on our test server:
           1.5-1.6 s a minute of game-thread time in the first minutes after a start, a 257 ms pass in the minute
           a player joined). A provider with no owner yet is checked again 30 s later instead of every 3 s; one
           or two due names wait up to 15 s and are then checked with one walk, never one lookup by path each;
           a repair batch walks each class even under 3 signs; and after its first piece a pass starts no other
           piece (repairs, a player-sync sweep, each half of a startup scan, provider checks) once it has used
           40 ms, leaving it for the next pass 3 s later. The background half is still plain Lua. The "bg" line
           adds due= (names due at the last pass) and deferred= (pieces left for a later pass).
v0.18.67: no lookup by path for a name the pass's own walk did not list (2026-11-14 lab on
           our test server: in the minute a player joined, one Travel Sign pass held the game thread
           for 3,627 ms with 61 lookups by path of about 60 ms each, and the first minutes after
           a start cost 1.4-3.7 s a minute). When a pass has walked a class, that walk lists
           every live object of it, so a name it does not list is gone or was renamed after the
           construction hook took it: treated as gone, no lookup. A pass that has not walked
           (under 3 names) still looks up by path, as before. Default__ names (a class's own
           template objects; never in a walk, never a placed sign) are no longer queued. The
           "bg" line counts the names treated as gone (gone=).
v0.18.66: the Travel Sign service no longer touches a game object from UE4SS's background thread
           (2026-11-13). Its provider checks (a lookup by path and GetOwner, a game function, per
           provider), the startup scan walks and the player-sync sweep ran on the background loop,
           against the v0.18.61 rule; the thread-safety test never reached that service. Now the
           background loop only decides when a pass is due and hands one pass to the game-thread
           pump, which does the same checks, scans, sweeps and repairs in the same order and at the
           same times, with one walk per class per pass. The startup scan checks each provider it
           walks right there (object in hand) instead of queueing 2,400-2,800 lookups by path; a
           provider with no owner yet still waits in the queue. Blueprint component templates
           (..._GEN_VARIABLE, owner never resolves) are no longer queued by the construction hook.
v0.18.65: the background service loop goes quiet while the world is paused (2026-11-13).
           On every server one unnamed background thread held 21-36% of one core with
           the world paused and nobody on (9 managed servers, 2026-11-11; a lab start on
           2026-11-01: 33-41%, before and after the pause). That thread is UE4SS's
           background thread for this mod, running the 1.5 s service loop below; the
           loop never looked at the pause. Now, while bw_pause's status file says
           paused=1 with connections=0 (written in the last 150 s), the Travel Sign
           service waits and the joiner check (a walk of every object for the player
           controllers) runs every 10th round instead of every round. The heartbeat,
           the roster write, gameplay settings, the Renown marker and the game-thread
           pump are unchanged. bw_pause lifts the pause the moment a client connects
           and rewrites its status, so the next round runs in full. One line a minute
           for the first 20 minutes after host-up, then every 10 minutes ("bg 60s:"),
           gives the loop's own time by part, so the next read names the cost.
           Off switches: HEARTH_BG_QUIET=0, or a file Logs\bw_bgquiet.off.
v0.18.64: the r19 release: v0.18.63 plus the Travel Sign pass that walks each class once instead of looking
           every object up by path (a join froze the world up to 6.2 s, three times; 2026-10-30 full pass).
v0.18.63: a Stop's save request goes to a controller with a player state, and one line says
           which was picked (2026-10-30, identity lab: "NOT confirmed within 20 s" with nothing logged).
v0.18.62: game-thread time is measured and one search cost is cut (2026-10-25).
           Boot (2026-10-26): the save request is served from the game-thread pump
           every 2 s from the first frame (a Stop in the first two minutes after a
           start used to kill unsaved), and the travel-sign provider check runs 40
           per background pass (sign providers first), so the background loop is no
           longer blocked 70-130 s after "listen server UP".
           Joined walls (2026-10-26): the wall the game joins into another and destroys
           is logged ("wall joined into ...") and dropped from the rebuild, scans and
           rechecks; only the wall that grew is rebuilt (it read "0 -> 0" and "1 without").
           The pump times every queued callback by label and counts the object
           lookups made inside them (by path: StaticFindObject; walks: FindAllOf),
           and logs one "gt 60s:" line a minute when any ran. The 10/24 fog lab
           read 50-70 ms for one lookup by path of a joiner's object on the game
           thread (inference from bw_fog's timing). The travel-sign repair looked
           up every remote pawn once per sign, three passes after every join; it
           now looks each pawn (and the blueprint library) up once per batch.
v0.18.61: game-thread work runs from one game-thread pump; the background
           service loop no longer calls UE4SS's ExecuteInGameThread, any
           hook registration or any game function (2026-10-18). In UE4SS b50986bd ExecuteInGameThread writes to the Lua
           stack the game thread is running on, with nothing locking the
           two. Now and then that left UE4SS's game-thread queue dead for the
           rest of the session ("Ref was not function": 11 of 54 sessions
           10/16-10/18, most with nobody on; roster, settings, joins help and
           the save before a Stop all stopped), or crashed the game inside a
           running callback (26 of 39 crashes in 10 days). The service loop
           now appends to a plain Lua queue that the pump drains every frame;
           the host start (OpenLevel, net driver swap), net tuning writes and
           the quarantine's identity-string writes run on the game thread;
           the join service reads Player/Pawn/PlayerNamePrivate instead of
           calling IsLocalPlayerController/K2_GetPawn/GetPlayerName.
           NotifyOnNewObject is registered from the pump's first run. A pump
           that stops for 60 s is logged and the heartbeat ends ",stalled",
           which the panel's Stop reads to wait for the game's own autosave.
           The startup fast pin (12 s of GameMode/GameEngine travel settings
           after host-up) is the one background write left, on purpose.
           tests/host-thread-safety.test.lua keeps it that way.
v0.18.60: palisade walls placed by players become build sites (four customer
           reports since 2026-09-05: invisible, never built, still block other
           buildings, can be demolished). The game makes each wall piece's
           construction site with the first player controller's character as
           builder; on this host that controller is the hidden host, which has
           no character, so every piece waited forever. After an accepted wall
           edit the server re-runs the wall's own update with the placing
           player's character in that slot for the one call, then empties it
           again. Walls saved in the stuck state are healed once a player is on,
           after a copy of the save (<save>.wallheal.bak). The spline census
           lists every spline actor and each wall's build-site count. Off
           switches: HEARTH_WALL_BUILDER=0, or a file Logs\bw_wallfix.off.
v0.18.59: (1) a game-thread callback that never runs no longer stops a
           service for good (see GAME_THREAD_WATCH below; one server lost
           its roster, settings, saves and join help for 58 h on 10/12).
           (2) two full object searches left the game thread (2026-10-14). The
           roster write searched every IpNetDriver on the game thread every
           service pass with a player on (every 9 s idle), and the viewport
           re-assert searched every GameViewportClient on the game thread
           every 15 s. Each search walks the whole object list and froze the
           server for 65-110 ms; on the fixed 30 fps step that is lost world
           time. The roster now reads the listen world's own net driver
           (kept by the service loop) and the viewport comes from the
           engine's GameViewport; each falls back to the old search only
           when that object is not known. Roster contents are unchanged.
v0.18.58: the false "Server full" after a fast reconnect (2026-09-16,
           seen again 2026-10-09 at PCs=4 against a cap of 5). The engine
           refuses a login with "Server full." when GameMode NumPlayers +
           NumTravellingPlayers reaches GameSession MaxPlayers, and on these
           hosts that sum can stay above the number of live controllers
           after a player reconnects before their old connection is reaped,
           until a restart. The heartbeat now logs the engine's count next
           to the live controllers (seats=) and, when the count stays above
           the live non-spectator controllers for two heartbeats in a row
           with no join or leave in between and nobody travelling, sets it
           back on the game thread. Log line: 'seat count corrected'.
           Kill switch: environment HEARTH_SEAT_HEAL=0. Also folds in the
           unreleased v0.18.56 dropped-controller change below (with its
           objectAddress use-before-definition fixed: it stopped the join
           service on every pass in the lab), and removes a MapFog sweep
           loop that had never run (same use-before-definition shape).
v0.18.57: a late joiner is no longer frozen. HearthServer drops a
           login-identities row 45 min after login. The conn of a player
           who stayed longer then failed its sticky lookup and recency-
           claimed the next fresh row, which was the newcomer's; the
           newcomer got no identity and was quarantined (no-login-
           identity) ~7 min later, and the old player took over the
           newcomer's roster id (and admin ticket, if any). Seen
           2026-10-10 on two servers. A conn that holds a claim now only
           re-claims a row with its own seed; a captured identity holds
           for the life of the controller (only weak -> Steam-backed may
           replace it); claims and identities keyed by object address
           are dropped when the address now holds a differently named
           conn or controller.
v0.18.56: (first shipped in v0.18.58) leave a real player's dropped
           controller to the game. A remote
           player whose connection dropped on the Halmare map had their
           orphaned controller frozen by the pre-login quarantine 9 s later
           (SetReplicates false, tick off, hidden) while the game kept it
           alive for 2.5 min; the rejoin 35 s after the drop came back with
           an empty character (2026-09-15). The quarantine now skips any
           controller that was serviced with a live connection, nothing is
           quarantined or start-driven on the TransitionMap, and the host's
           own controller is recognised by object address across a travel
           (its full name changes per map; it was quarantined on the return
           trip). Log line: 'remote player connection dropped, controller
           left to the game'.
v0.18.55: Renown readout and a staff repair lever. A remote player's
           Renown went to -14,560 after a time skip on the islands. In
           this build the HUD number is TotalRenown minus the Renown
           "used" by recruited villagers and structures (UMistHiring-
           ValueComponent::UpdateUsedRenown, recomputed on data rebind and
           snapshotted per map on a voyage); daily militia/mercenary
           upkeep is paid in coins, never Renown. The mod now logs the
           hiring component's readable properties at install, after each
           world change and around every Renown movement it can hook
           (PayRenownCost, MulticastRenownGained, ServerGiveRenown), and
           honours an operator marker Logs\bw_renown.marker holding one
           integer: GiveRenown(n) through the game's own cheat component,
           logged before/after, marker removed. Nothing runs without it.
v0.18.54: (1) a seamless travel passes through /Game/Mist/Maps/Dev/
           TransitionMap for ~25 s; v0.18.50 took THAT as the world change
           and its 60 s throttle swallowed the real destination, so the
           Travel Sign sweep re-ran against the transition map. In-transit
           worlds are ignored now; the destination is the change.
           (2) Log-only diagnostics for the two open reports on a remote
           player's map after a voyage and their palisade after Place:
           the seamless-travel handshake (ServerFinishSeamlessTravelSetup,
           ClientPostSeamlessTravelSetup, the ClientSendIcon* stream and
           ServerKeyValuesAck per player), the four Client spline replies,
           a property dump of the wall actor after every accepted edit and
           the construction-site count before/after. Nothing else changes.
v0.18.53: flush spline dormancy BEFORE the game edits replicated points.
           Waking afterward can initialize the replication comparison from
           the already-modified state and lose the update. Request the net
           update after the edit; combining splines handles both actors.
v0.18.52: wake the wall/road actor after every server-side spline edit.
           v0.18.51's log proved the mechanism: the server accepts each
           segment (points 1->2->3, versions match) but the spline actor
           is DORM_DormantAll and AddPoints never flushes dormancy, so the
           new points never reach a remote player. Their game, still
           holding a one-point copy, cancels the placement and asks the
           server to remove "the lone post" (rejected: stale version), and
           the wall they placed is invisible until they rejoin. A listen
           host never sees this (it reads server state directly). Now the
           post-hook of every spline edit RPC calls FlushNetDormancy +
           ForceNetUpdate on the actor, the engine's own idiom for a
           dormant actor that just changed.
v0.18.51: Splineworks (palisade wall / road) server-side diagnostics. A
           remote player's wall preview vanishes on confirm and the game
           logs nothing. The server's ServerExtendSpline rejects an edit
           when the version the client sends differs from the actor's
           replicated EditVersion, or when the segment cannot be crafted
           (walls cost nothing, so only the version gate applies). Every
           spline RPC is now logged with both versions and the actor's
           replication settings. Log-only, pcall-wrapped, no handles kept.
v0.18.50: stop holding UObject handles across ticks. Three host crashes
           (one server: 2026-08-29, 2026-09-05, 2026-09-06) symbolized against
           the pinned UE4SS b50986bd PDB: two access violations inside the
           UE4SS call thunk / object wrapper while a queued game-thread
           callback called a UFunction with a component, provider, icon class
           or pawn handle the Travel Sign code had kept from an earlier tick,
           and one process abort from a Lua error escaping a LoopAsync body.
           Travel Sign memory now stores object PATHS and resolves each one
           through StaticFindObject on the game thread at the moment of use,
           remote pawns are resolved the same way, every LoopAsync body runs
           under pcall, and a live-world change (the Halmare voyage and the
           trip back are ServerTravel) clears the Travel Sign memory and
           re-runs the startup sweep so the map is not empty until a restart.
v0.18.49: apply host-managed gameplay settings through a build-locked
           native server path. Bellwright's own SaveChanges deliberately
           skips persistence on NM_Client, so a remote player's host flag
           can never save these values. The native helper runs only on the
           game thread, verifies the exact retail executable, invokes the
           authoritative UMistGameSettingsData setters, mirrors the game's
           persistence-dirty calls, and writes exact readback status. Keep
           polling the immutable config revision so Apply works live and
           startup readiness can fail closed on missing/mismatched settings.
v0.18.48: bound the late-spawn Travel Sign sweep to startup instead of
           walking every map-icon provider for the lifetime of the host.
           Remember non-travel providers after their owner resolves, rely
           on the existing object hooks for later arrivals, and protect
           every queued game-thread callback with a Lua-level pcall so an
           ordinary callback error cannot enter UE4SS's unsafe traceback
           path and terminate the host process.
v0.18.47: permit only the MapFog actor tick after all four build-locked
           null-RHI patches verify. Keep every component tick disabled. The
           missing fourth patch skips the exact UMapRevealerComponent virtual
           call whose null Canvas caused both v0.1.77 crashes at 62 seconds.
v0.18.46: keep looking for Travel Signs instead of trusting one boot-time
           sweep. On a loaded save the Fast Travel components can spawn after
           that sweep, which returned components=0 providers=820 on a live
           server; the scan was one-shot, so nothing ever looked again and
           only a sign that happened to arrive through the runtime hook was
           ever repaired. Rescan on an interval, clear give-up markers so a
           component that failed only because its owner was not ready yet is
           retried, and always sweep the world on a player sync pass instead
           of only when nothing has been remembered — that guard meant one
           known sign permanently disabled the search for the rest.
v0.18.45: deliver the granted admin flag to a client whose pawn went dormant,
           and stop trusting a silent write. ForceNetUpdate only flushes net
           dormancy when it can resolve a NetDriver for the actor, so a
           DORM_Initial pawn keeps its opening bunch and never sends the
           property again. Call FlushNetDormancy explicitly, republish the
           write across the first few service ticks, and log the read-back
           value plus the dormancy state so a locked client can be told apart
           from a failed write. No change to who may be granted authority.
v0.18.44: replay completed Travel Signs through Bellwright's reflected
           ServerRepairTravelComponent RPC for each ready remote player.
           Keep the existing bounded road/icon refresh and MapFog guard;
           this remains scoped to completed FastTravelSign_C actors.
v0.18.43: publish the authenticated bIsHostPlayer write to the owning client.
           bIsHostPlayer is a replicated native property and this build links
           Unreal's push-model replication, so the direct write never left server
           memory and the gameplay-settings UI stayed locked. Mark the property
           dirty through the reflected UNetPushModelHelpers and force a net update
           on the owner, and disable push model pre-host when an admin is
           configured so the listen server's rep layouts never skip the compare.
           No change to who may be granted authority.
v0.18.42: consume the authenticated admin ticket from HearthServer's
           validated login cache when UE4SS cannot reflect RequestURL.
v0.18.41: grant Bellwright's replicated bIsHostPlayer authority only after
           a one-use HearthServer ticket proves the RCON/admin password and
           binds the configured Steam64 identity to the connection source.
v0.18.40: promote a newly completed Travel Sign to the bounded player-sync
           path when remote players are already connected. This refreshes
           that sign's road graph and false/true discovery state without
           enabling MapFog or replaying unrelated map icons.
v0.18.39: replay completed Travel Sign discovery after a remote player's
           map-icon manager and possessed pawn are ready. Bellwright ignores
           a repeated true-only discovery request once the provider is
           already marked, so use its built-in false/true transition in
           three bounded post-join passes and refresh the sign road graph.
v0.18.38: pair Travel Sign and map-icon-provider subobjects through their
           shared actor owner. Provider construction can lag the fast-travel
           component by more than the bounded retry window; the provider
           object hook now re-arms that exact sign when it becomes ready.
v0.18.37: keep MapFog fully disabled under null-RHI and repair only completed
           Travel Sign discovery through Bellwright's built-in
           SetMapIconDiscovered path. Full MapFog ticking still crashes after
           the known render paths are patched.
v0.18.35: invoke the already-validated operator save component directly
           after the game-thread handoff. Revalidating the reflected object
           inside the callback can stall the Unreal game thread.
v0.18.34: make operator save-component resolution fail-safe. Validate
reflected objects inside protected calls, fall back to a bounded class
scan, and surface service-loop errors instead of silently swallowing the
request while its port-scoped marker remains pending.
v0.18.33: resolve the native cheating component from the established
service loop before queueing the game-thread save call. A fresh full-object
lookup inside the callback can abort the callback before it logs or clears
the marker; the queued callback now only validates and invokes the cached
component, with every callback error logged and retried safely.
v0.18.32: place operator force-save markers beside the host log, where
the live UE4SS process already has proven read/write access. Keep the
Windows Temp marker as a compatibility fallback and remove every scoped
copy after one successful native save request.
v0.18.31: support a port-scoped operator force-save marker. Resolve
Bellwright's reflected cheating component and invoke its native Auto-slot
save on the game thread, so recovery can be verified without a test player.
v0.18.30: continue the existing TEMP auto-save through Bellwright's native
travel options instead of opening Karvenia as a new game. Preserve the
listen port and paid player capacity on the same travel URL.
v0.18.29: require the safe UE4SS field sentinel and check IsValidField
before optional reflected property reads/writes. A missing field can appear
during UObject teardown/GC; never dereference that invalid-field sentinel.
v0.18.28: remove direct runtime mutation of live NPC Mutable components;
Bellwright can be inside an asynchronous skeletal-mesh update when those
UE4SS native calls fire, causing an uncatchable game-thread access violation.
Keep the safe cvar/render suppression only. Give native persistence a full
grace window before retrying HandleStartingNewPlayer so an existing player
record can resolve before the host drives the start handler again.
v0.18.27: preserve Bellwright's native persistent-player lifecycle. The
login URL's stable Name is consumed by InitNewPlayer before PostLogin; do
not overwrite PlayerState/controller/connection identity afterward. Retry
HandleStartingNewPlayer on the game thread while persistence finishes
loading instead of forcing RestartPlayer, which creates an unbound default
pawn with no AMistPlayer state. Leave streaming, movement, customization,
and cinematic readiness to Bellwright's normal player-start flow.
v0.18.26: strip the UTF-8 BOM from the first login-identity timestamp so
the first player after restart is immediately claimable. Keep the identity
grace beyond the 150s cache window and never re-service a quarantined PC.
v0.18.25: keep join/identity servicing alive when UE4SS transiently exposes
ClientConnections with a nil array count. Treat that tick as empty instead
of throwing out of serviceJoiners; later ticks resume the live connections.
v0.18.24: apply the paid player capacity to Bellwright's native GameSession.
Bellwright's hidden listen host consumes one native seat, so a 4-player
dedicated host needs MaxPlayers=5 to admit four real remote players. The
supervisor/A2S count remains 4 because the hidden host is never customer-visible.
v0.18.23: recency-claim fallback for the login identity cache. On some
endpoints UE4SS exposes BOTH UNetConnection.RequestURL and the remote
address as unreadable object proxies, so the v0.18.21 byAddress/byLogin
lookups can never match and the REAL joiner got quarantined after the 30s
grace (interactions dead and the pawn hidden server-side). Now an
unmatched live remote conn claims the oldest UNCLAIMED fresh (<150s) row
from login-identities.tsv — Bellwright's LogNet login and the controller
creation are seconds apart, so time-proximity is authoritative when direct
matching is blind. Each row is handed out once (claim registry), claims are
sticky per connection, and the pre-login grace is raised 30s -> 75s for
slow-loading clients. Genuinely identity-less controllers still quarantine.
v0.18.22: clear a stale roster at idle. writeRoster was only called when a
remote joiner was live, so after the last player left (or a restart) the last
non-empty roster.json persisted forever -> the launcher showed a phantom
"1 player, no name, always there" (often a pre-guard UScriptStruct identity).
Now the idle service loop refreshes the roster every ~9s so it self-clears to
players:[]; safe because the IpNetDriver scan is cheap under -nullrhi.
v0.18.21: use HearthServer's Bellwright LogNet login identity cache when
UE4SS exposes UNetConnection.RequestURL as a transient UObject proxy.
v0.18.20: guard diagnostic World.TimeSeconds math when UE4SS returns an
Unreal property proxy instead of a Lua number, so join servicing cannot throw.
v0.18.19: add a low-risk post-host liveness heartbeat and retire the
high-frequency travel-pin loop shortly after listen startup so repeated
UObject travel probes cannot wedge the Lua VM while the game keeps ticking.
v0.18.18: keep the post-travel host loop alive even when GameInstance lookup
disappears after OpenLevel, so idle heartbeat/join servicing continues.
v0.18.17: prefer the launcher's Steam-backed PlayerId / PlatformUserId over
generated ?Name values for reconnect/save identity.
v0.18.16: keep once-identified local host phantom controllers out of the
remote joiner path even if Bellwright later reports them as non-local.
v0.18.15: only spawn/possess controllers after a live NetConnection has a
stable Hearth login identity, and isolate stale pre-login controllers so
failed handshakes cannot become sleeping/interacting ghost players.
v0.18.14: reject transient UE object strings (UScriptStruct/UObject/etc.)
as player identities; clear them before spawn instead of saving them as
reconnect keys.
v0.18.13: reconnect/save identity fix — seed the joiner's PlayerState/PC string fields
from the direct-IP login URL before forced RestartPlayer, and stop roster ids from
falling back to transient UObject addresses.
v0.18.12: TICK-RATE fix — cache hot FindFirstOf lookups + kill the per-pass full-object bench scan; the continuous GUObjectArray walks (UObjectArrayCache off) held the UE4SS Lua lock ~100% and serialized every engine frame to ~1.5s (0.65fps, joiners frozen).
v0.18.11: roster/player-count fix — count every live ClientConnection, no longer
drop connections whose OSS=Null PlayerState name looks generated (the "0 of 4
forever" A2S count bug; name stays cosmetic, count is ground-truth connections).
```
