# Changelog

All notable changes to HearthServer are documented here. The version here is
kept in lockstep with the `HumanGenome/HearthClient` release tag and the
`Directory.Build.props` `<Version>`.

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
