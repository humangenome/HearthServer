# Changelog

All notable changes to HearthServer are documented here. The version here is
kept in lockstep with the `HumanGenome/HearthClient` release tag and the
`Directory.Build.props` `<Version>`.

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
