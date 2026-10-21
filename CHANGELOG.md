# Changelog

All notable changes to HearthServer are documented here. The version here is
kept in lockstep with the `HumanGenome/HearthClient` release tag and the
`Directory.Build.props` `<Version>`.

## [0.1.95] - 2026-10-21

Hardening of the admin HTTP routes. A signed request with a body over 64 KB, such as a world upload, now sends its SHA-256 in `X-Hearth-Content-Sha256`, and without it the server answers that the Hearth app needs updating (Hearth app 0.1.95 sends it). Public reads (health, players, manifest) have their own request slots, separate from the signed routes, and only one world upload runs at a time. `GET /api/v1/chat/recent` and `GET /api/v1/chat/motd` now need the admin signature, and the unused `POST /api/v1/chat/player` is removed; admin messages still go out through RCON `say` and `announce`. Also: RCON `players` lists each player's name and time on the server, and `status` says whether the world is running.

## [0.1.94] - 2026-10-19

The host no longer loses its game-thread work for the rest of a session, and a set of crashes is gone. The host mods' background loop handed work to the game thread through UE4SS's `ExecuteInGameThread`, which on the UE4SS build Hearth ships writes to the same Lua stack the game thread is running on, with nothing keeping the two apart. When they collided, either UE4SS logged "Ref was not function", removed its game-tick hook and ran no queued work again until a restart (player list, gameplay settings, join help and the save before a stop all stopped; the 0.1.92 retry could not bring it back), or the game crashed inside a running callback. `bw_host` v0.18.61, `bw_fog` v0.1.4 and `bw_seat4` v0.1.2 now hand work over through a plain list that one loop on the game thread works through every frame, and register everything with UE4SS from that loop. Under a load that broke the old code within a minute, twice, the new code ran 36 minutes with two players on and dropped nothing. A new check (`tests/host-thread-safety.test.lua`) fails if background code in the host mods calls a UE4SS game-thread or hook function, or a game function. Also: `host-instance.ps1 -Stop` and `-Restart` wait for the game's own next autosave (when it is due within 150 seconds) if the host mod reports its game-thread loop has stopped, instead of asking for a save that cannot run; `host-instance.ps1` sets the CPU pin up to six times before giving up a launch attempt, because the game resets its own affinity during its first minute; the server reports the game's Steam build from the install's `steamapps` manifest instead of the `UE5-CL-0` banner; and the host log says when a player takes a wall down.

## [0.1.93] - 2026-10-17

Palisade walls placed by players are built again. Bellwright makes each wall piece's build site with the host player's character, and a Hearth host has no character of its own, so every wall stayed an invisible line that villagers never built but that still blocked other buildings and could be demolished. After a wall is placed or extended, `bw_host` v0.18.60 runs the game's own wall update with the placing player's character standing in for that one call, then puts the host back as it was. Walls already saved in that state get their build sites the first time a player is on, after the host writes a copy of the save next to it (`TEMP_auto.sav.wallheal.bak`). In a test on an affected world, the three stuck walls got 8, 27 and 5 build sites, villagers finished 21 pieces of the long one within eight in-game hours, and everything was still there after a restart. Off switches: `HEARTH_WALL_BUILDER=0`, or a file named `bw_wallfix.off` in the host's `Logs` folder. The wall census in `bw_host.log` now lists every road and wall and each wall's build-site count (`NO-BUILD-SITE` marks a stuck one), and a new check runs in CI (`tests/host-wall-builder.test.lua`).

## [0.1.92] - 2026-10-16

Worlds keep real time. The host steps the world at a fixed rate, and the `bw_fog` map-fog mod searched the game's whole object list twice every 2 seconds on the game thread, even with nobody on, so every search was world time lost. `bw_fog` v0.1.3 remembers the connected players and searches again only when someone joins, leaves or travels, or every 30 seconds (2 minutes with nobody on). In a test world, idle time went from 97.7% to 99.95% of real time, and with two players moving from 96.0% to 97.1%; worlds with more buildings and villagers gain more. `bw_host` v0.18.59's player roster and display check no longer search on the game thread either. Fixed: when the game dropped a task the host had queued for its game thread (seen once as "Ref was not function" in the UE4SS log), the roster, gameplay settings, saves, join help and map-fog reveal stopped until the next restart; a task that has not run after 120 seconds is now given up and queued again, and the fog and fourth-place mods recover the same way. Also: `host-instance.ps1` refuses Windows builds older than 18363 (such as Windows Server 2019) and says why, the supervisor is on MessagePack 3.1.9 (GHSA-qhrr-8q5h-9q3h: nested arrays could get past the reader's length limits), and three new host-mod checks run in CI (`tests/fog-scan-budget.test.lua`, `tests/host-scan-budget.test.lua`, `tests/host-gamethread-watch.test.lua`).

## [0.1.91] - 2026-10-12

A fourth player can now join: Bellwright counts its own host as one of four places and sends world data to only three joining players, and the host package frees the hidden host's place and sends a fourth player that data (the `bw_seat4` mod with `HearthFourthSeat.dll`). Fixed: a player who joined 45 minutes or more after a friend could freeze about seven minutes later; a server could refuse every join with "Server full" after a quick reconnect until it was restarted; a player whose connection dropped had their character frozen by the host while the game still held it for a rejoin; a save left as zeros by a power loss stopped every start, and now the newest intact copy takes its place; `host-instance.ps1 -Stop` and `-Restart` closed the game without saving, and now ask for a save and wait up to 20 seconds for it; the player count showed the last session's players after a restart; after a trip to the islands the host latched on to the transition map. Also: the game's warning spam about quests with no player is no longer written, memory clean-up runs every 3 minutes instead of every minute, and the host keeps its last three session logs.

## [0.1.90] - 2026-09-07

The whole server side is now open source and published here. This release adds
the complete host package, `HearthServer-Host-Windows-x64-v0.1.90.zip`: the
supervisor, the UE4SS runtime with the `bw_host` and `bw_fog` mods and their
signature packs, the native gameplay-settings and map-fog helpers, the Engine.ini
templates and `host-instance.ps1`, which stages UE4SS, launches Bellwright
headless, applies the native crash guards and supervises the process. Extract it,
point the script at a Bellwright install, and players can join through the
Hearth app. The supervisor-only archive is still published for anyone who only
wants the sidecar. The player app stays closed source.

## [0.1.89] - 2026-09-01

Version-lockstep release with Hearth v0.1.89. The bundled Bellwright host is
re-cut for Bellwright's 2026-09-01 Steam build (24840601): the build-specific
UE4SS signature and the startup memory-address checks behind the host's
safeguards are re-derived, and the server-authoritative gameplay settings module
is re-verified against the new executable. There are no behavioral changes to the
public .NET supervisor source in this repository.

## [0.1.88] - 2026-08-05

Version-lockstep release with Hearth v0.1.88. The bundled Bellwright host now
binds map updates to connected players, bounds its startup discovery work, and
isolates recoverable game-thread callback errors. There are no behavioral
changes to the public .NET supervisor source in this repository.

## [0.1.87] - 2026-07-31

Version-lockstep release with Hearth v0.1.87. The bundled Bellwright host now
publishes authenticated gameplay-settings authority to the configured admin's
owning client and reports its exact host-mod version. There are no behavioural
changes to the public .NET supervisor source in this repository.

## [0.1.85] - 2026-07-30

- Rebuild of the v0.1.84 server package with no functional change. The binaries no
  longer carry the build machine's directory layout or a debug link back to where they
  were compiled, and the build now fails if either comes back.

## [0.1.84] - 2026-07-25

- Validates a presented Bellwright admin ticket against the configured Steam64
  ID and accepted source address in the server's raw login stream.
- Carries only the validated one-use grant through the server-local identity
  cache when the host mod cannot reflect Bellwright's connection URL.

## [0.1.83] - 2026-07-23

- Adds RCON-authenticated, short-lived admin join tickets bound to a configured
  Steam64 ID and connection address.
- Grants Bellwright's native host-player gameplay-settings authority only after
  the host overlay consumes a matching one-use ticket.
- Redacts join passwords and admin tickets from HearthServer's mirrored game logs.

## [0.1.82] - 2026-07-22

Version-lockstep release with Hearth v0.1.82. This release hardened launcher
resource use and version checks; there were no behavioral changes to the public
.NET server source in this repository.

## [0.1.81] - 2026-07-17

Version-lockstep release with Hearth v0.1.81. The bundled Bellwright host makes
Travel Signs available immediately when they are completed during an active
multiplayer session. There are no behavioral changes to the .NET server source
in this repository.

## [0.1.80] - 2026-07-17

Version-lockstep release with Hearth v0.1.80. The bundled Bellwright host now
replays completed Travel Sign road and icon state after a player is ready so
existing-world destinations reach newly joined players. There are no behavioral
changes to the public .NET server source in this repository.

## [0.1.79] - 2026-07-17

Version-lockstep release with Hearth v0.1.79. The bundled Bellwright host now
waits for delayed Travel Sign map-icon providers before applying discovery.
There are no behavioral changes to the public .NET server source in this
repository.

## [0.1.78] - 2026-07-17

Version-lockstep release with Hearth v0.1.78. The bundled Bellwright host now
uses the game's targeted fast-travel icon path for completed Travel Signs while
keeping map fog disabled on headless servers. There are no behavioral changes
to the public .NET server source in this repository.

## [0.1.77] - 2026-07-17

Superseded by v0.1.78. This version's broader map-fog approach was not retained
because it was unsafe on null-rendering headless hosts. There were no behavioral
changes to the public .NET server source in this repository.

## [0.1.76] - 2026-07-16

Version-lockstep release with Hearth v0.1.76. The bundled Bellwright host and
client runtime now support Bellwright Steam build 24204729. There are no
behavioral changes to the public .NET server source in this repository.

## [0.1.75] - 2026-07-14

- Invokes Bellwright operator saves through the already-validated component
  after the game-thread handoff, avoiding a redundant reflected-object check
  that could stall the callback.
- Records game-thread callback entry while retaining the request marker until
  the save invocation succeeds.

## [0.1.74] - 2026-07-14

- Makes Bellwright operator save requests retry safely when Unreal reflection
  is temporarily unavailable and records the failure reason in the host log.

## [0.1.73] - 2026-07-14

Version-lockstep release with Hearth v0.1.73. The launcher now verifies and
repairs stale, missing, or damaged HearthConnect files before joining. There
are no behavioral changes to the .NET server source in this repository.

## [0.1.72] - 2026-07-14

- Makes the authenticated Bellwright `save game` command reliably reach the live game-thread save function.
- Keeps failed save requests pending with a clear host-log reason instead of silently losing the callback.

## [0.1.71] - 2026-07-14

- Writes native Bellwright save-request markers beside the managed game PID
  file so the live UE4SS host can consume them reliably.

## [0.1.70] - 2026-07-14

- Adds authenticated RCON `save game` to request a port-scoped native
  Bellwright save for recovery verification.

## [0.1.69] - 2026-07-14

- Waits for Bellwright's rotating save set to settle before live protection
  reads it.
- Detects a live world regression without rewriting files that the game is
  actively rotating, while preserving the verified offline baseline for the
  next safe startup recovery.

## [0.1.68] - 2026-07-14

Version-lockstep release with Hearth v0.1.68. The bundled Bellwright host now
guards optional game fields during player and world-object cleanup, preventing
server crashes during joins, disconnects, and garbage collection. There are no
behavioral changes to the .NET server source in this repository.

## [0.1.67] - 2026-07-13

- Keeps the running Bellwright world online after repairing a regressed
  automatic save, avoiding an autosave restart loop while preserving the
  verified world rotation on disk.

## [0.1.66] - 2026-07-13

- Publishes the Bellwright world-regression guard with matching 0.1.66 Windows
  binary metadata so managed installations update cleanly.

## [0.1.65] - 2026-07-13

- Protects complete Bellwright worlds when a crash or bad rotation falls back
  to a starter-state save.
- Repairs inconsistent rotating saves before launch and recycles the owned
  game process after a live regression is recovered.
- Resets save-protection state when a snapshot or imported world intentionally
  replaces the current world.

## [0.1.64] - 2026-07-13

- Keeps offline player records protected after every Bellwright automatic save,
  including installations where snapshot archives are disabled.

## [0.1.63] - 2026-07-13

- Preserves established offline player records when Bellwright rewrites an
  idle world save.
- Verifies the protected save before replacing the live file and refuses an
  unsafe launch if protection cannot complete.

## [0.1.62] - 2026-07-13

Version-lockstep release with Hearth v0.1.62. The host bundle prevents a
Bellwright crash during asynchronous character mesh updates and protects
existing character progress while persistent player data resolves after a
join. There are no behavioral changes to the .NET server source in this
repository.

## [0.1.61] - 2026-07-13

Version-lockstep release with Hearth v0.1.61. The launcher now preserves
existing Bellwright characters across Hearth updates and local-data cleanup,
while keeping native character creation available for genuinely new players.
There are no behavioral changes to the .NET server source in this repository.

## [0.1.60] - 2026-07-12

Version-lockstep release with Hearth v0.1.60. The bundled Bellwright host now
uses the game's native persistent-player lifecycle for character restoration,
possession, customization, inventory, quests, and interactions. There are no
behavioral changes to the .NET server source in this repository.

## [0.1.59] - 2026-07-11

- Fixes the first player after a server restart being treated as unidentified
  and becoming invisible.
- Keeps player join and visibility handling active when Bellwright briefly
  returns incomplete connection data.

## [0.1.58] - 2026-07-11

- Keeps player join and visibility handling active when Bellwright briefly
  returns incomplete connection data.
- Prevents a later player from joining as an invisible or non-interactive
  character.

## [0.1.57] - 2026-07-11

Version-lockstep release with the Hearth v0.1.57 host update. No changes to
the .NET server source in this repository; the in-game host mod now keeps
player join and visibility handling active when Bellwright briefly returns
incomplete connection data.

## [0.1.56] - 2026-07-11

- Fixed login identity tracking when Bellwright exposes the connection address
  and request URL as unreadable object proxies.
- Added a recency-safe identity cache so simultaneous players retain separate,
  stable identities instead of becoming invisible or unable to interact.
- Stopped stale accepted connection addresses from being paired with later
  logins.

## [0.1.47] - 2026-07-05

- Fixed the Source Query (A2S) responder so transient UDP socket errors do not
  stop the query loop while the server process remains alive.

## [0.1.42] - 2026-07-03

Version-lockstep release with the Hearth v0.1.42 host performance update. No
changes to the .NET server source in this repository — the update lives in the
host launch recipe and the in-game host mod, which ship with the launcher/host
bundle:

- Dedicated hosts no longer run a software renderer; the world simulation now
  ticks at the full engine rate on GPU-less machines (joining players
  previously saw a frozen world).
- Host-side character-customization rebuild removed (fixed a rare join crash);
  head generation is fully client-side as of v0.1.41.

## [0.1.8] - 2026-06-15

Initial public source release of HearthServer — the .NET 8 dedicated-server
supervisor for **Bellwright** (UE5.7) multiplayer hosting.

- Process supervisor + heartbeat watchdog for the Bellwright dedicated server
- Source Query (A2S) responder so the server shows up to clients and the panel
- Source RCON server for remote console/admin commands
- SQLite-backed persistence (bans, schedule, audit log)
- Local loopback admin API consumed by the Hearth launcher
