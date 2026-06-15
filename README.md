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

## Build

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```bash
dotnet restore HearthServer.sln
dotnet build HearthServer.sln -c Release
dotnet test  HearthServer.sln -c Release
```

Publish a self-contained Windows build (what releases ship):

```bash
dotnet publish src/server/HearthServer/HearthServer.csproj \
  -c Release -r win-x64 --self-contained true
```

Tagged releases (`vX.Y.Z`) build, test, publish, and attach
`Hearth-Server-Windows-x64-<tag>.zip` automatically via GitHub Actions.

## Layout

```
src/shared/Hearth.Protocol       wire types shared with the launcher
src/shared/Hearth.Abstractions   shared interfaces
src/server/Hearth.SourceQuery    A2S responder
src/server/Hearth.Rcon           Source RCON server
src/server/Hearth.Persistence    SQLite store (bans/schedule/audit)
src/server/HearthServer          the supervisor host (entry point)
```

## Official hosting

HearthServer is officially supported by
[SurvivalServers.com](https://www.survivalservers.com/games/bellwright/) —
managed Bellwright hosting with Hearth pre-installed and kept on the latest
pinned release. Self-hosting is fully supported from this source.

## License

[MIT](LICENSE) © HumanGenome
