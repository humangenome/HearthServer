# Changelog

All notable changes to HearthServer are documented here. The version here is
kept in lockstep with the `HumanGenome/HearthClient` release tag and the
`Directory.Build.props` `<Version>`.

## [0.1.8] - 2026-06-15

Initial public source release of HearthServer — the .NET 8 dedicated-server
supervisor for **Bellwright** (UE5.7) multiplayer hosting.

- Process supervisor + heartbeat watchdog for the Bellwright dedicated server
- Source Query (A2S) responder so the server shows up to clients and the panel
- Source RCON server for remote console/admin commands
- SQLite-backed persistence (bans, schedule, audit log)
- Local loopback admin API consumed by the Hearth launcher
