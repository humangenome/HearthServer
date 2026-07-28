# HearthServer

[![Platform](https://img.shields.io/badge/Platform-Windows_10%2F11-blue.svg)](#build)
[![Game](https://img.shields.io/badge/Game-Bellwright-darkgreen.svg)](https://store.steampowered.com/app/1812450/)
[![Runtime](https://img.shields.io/badge/.NET-8.0-512BD4.svg)](https://dotnet.microsoft.com/)
[![Client](https://img.shields.io/badge/Client_App-Hearth-brightgreen.svg)](https://github.com/HumanGenome/Hearth)

**HearthServer** is the dedicated-server supervisor behind **Hearth**, the hosting
stack that gives [Bellwright](https://store.steampowered.com/app/1812450/) (UE5.7)
reliable, panel-manageable multiplayer servers. It wraps the Bellwright dedicated
server with the operational plumbing a real host needs: process supervision,
crash recovery, server query, RCON, persistence, and a local admin API the
Hearth launcher drives.

This repository is the **server source**. The player-facing launcher and the
packaged installer are distributed from [HumanGenome/Hearth](https://github.com/HumanGenome/Hearth).

## What it does

- **Process supervisor + watchdog** — launches the Bellwright dedicated server,
  watches its heartbeat, and recovers it on crash or hang.
- **Source Query (A2S)** — answers A2S so the server is visible to clients and to
  the hosting panel's status checks.
- **Source RCON** — standard Source RCON for remote console and admin commands.
- **Persistence** — SQLite-backed bans, scheduled tasks, and an audit log.
- **Local admin API** — a loopback-only control plane the Hearth launcher uses to
  start/stop, configure, and query the server.

## What it cannot do on its own

The supervisor does not make Bellwright joinable, and this repository does not
publish the piece that does.

Bellwright's packaged build ships `SteamSocketsNetDriver` as its only net
driver and ignores an `Engine.ini` override of it. The swap to Unreal's
`IpNetDriver`, and the call that opens the world as a direct-IP listen server,
both happen at runtime inside a host-side UE4SS mod (`bw_host`). That mod is
not in this repository and is not published anywhere else either, and neither
are the AOB signature files UE4SS needs to resolve the engine internals of that
build.

Point the published archive at a Bellwright dedicated install and you get a
working supervisor wrapped around a game process that never opens a joinable
world. RCON answers, A2S answers, the admin API answers, saves are protected,
crashes are recovered — and no Hearth client can connect.

So, plainly: **you cannot build a joinable Bellwright server out of what is
published here.** Nothing has been stripped out of the supervisor to force
that. The supervisor is complete, it builds from this source, and its tests
pass; the host mod is a separate component that stays private.

Closing the gap yourself means writing your own UE4SS host mod for Bellwright —
rewrite `NetDriverDefinitions[GameNetDriver]` to
`/Script/OnlineSubsystemUtils.IpNetDriver` at runtime, then open the stock map
with a `listen` URL on your gameplay port.
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) is open source and that is a
legitimate route, but it is reverse-engineering work against a shipping UE5.7
title rather than a build step, and it has to be redone when the game's layout
moves.

This section replaces a line that used to sit at the bottom of this page:
"Self-hosting is fully supported from this source." That was not accurate, and
it stayed here through v0.1.84.

## Build

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).
`HearthSaveGuard.exe` is written in Rust, so building the full release payload
also needs a [Rust toolchain](https://rustup.rs/).

```bash
dotnet restore HearthServer.sln
dotnet build HearthServer.sln -c Release
dotnet test  HearthServer.sln -c Release
cargo test --manifest-path src/tools/Hearth.SaveGuard/Cargo.toml --release
```

Publish a self-contained Windows build (what releases ship):

```bash
dotnet publish src/server/HearthServer/HearthServer.csproj \
  -c Release -r win-x64 --self-contained true
cargo build --manifest-path src/tools/Hearth.SaveGuard/Cargo.toml --release
```

Release CI copies the built `HearthSaveGuard.exe` next to the published
`HearthServer.exe` before zipping. Tagged releases (`vX.Y.Z`) build, test,
publish, and attach `HearthServer-Supervisor-Windows-x64-<tag>.zip`
automatically via GitHub Actions.

## Layout

```
src/shared/Hearth.Protocol       wire types shared with the launcher
src/shared/Hearth.Abstractions   shared interfaces
src/server/Hearth.SourceQuery    A2S responder
src/server/Hearth.Rcon           Source RCON server
src/server/Hearth.Persistence    SQLite store (bans/schedule/audit)
src/server/HearthServer          the supervisor host (entry point)
src/tools/Hearth.SaveGuard       Rust save-protection helper (HearthSaveGuard.exe)
tests/                           xUnit suites for the protocol, server, and save paths
```

## What this repository ships

`HearthServer-Supervisor-Windows-x64-<tag>.zip` on this repo's release page is
the self-contained **supervisor** build and nothing else: `HearthServer.exe`,
its .NET runtime, and `HearthSaveGuard.exe`. Extract it and run
`HearthServer.exe` from the extracted folder.

The name matters. Releases before v0.1.85 called this archive
`Hearth-Server-Windows-x64-<tag>.zip`, which is also the name of a larger
archive built on a private release line: the complete host package, supervisor
plus host runtime, which is not published. Anything published from this
repository is the supervisor.

It does not include Bellwright itself, and it does not include the host-side
UE4SS runtime — see
[What it cannot do on its own](#what-it-cannot-do-on-its-own) for what that
means in practice.

## Official hosting

HearthServer is officially supported by
[SurvivalServers.com](https://www.survivalservers.com/services/game_servers/bellwright/?utm_source=github&utm_medium=readme&utm_campaign=hearthserver),
which runs Bellwright servers with Hearth installed and kept on the latest
pinned release.

## License

[MIT](LICENSE) © HumanGenome
