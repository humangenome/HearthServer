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

This repository is the **whole server side**: the supervisor, the host-side
UE4SS mods (`bw_host`, `bw_fog`), their native helpers, the signature packs and
the launch script. Its release page ships a complete host package you can run.
The player-facing app is closed source and is distributed from
[HumanGenome/Hearth](https://github.com/HumanGenome/Hearth).

## What it does

- **Host runtime** — `bw_host`, a UE4SS mod that swaps Bellwright's net driver
  to Unreal's `IpNetDriver` at runtime and opens the world as a direct-IP
  listen server, with no GPU, no Steam client and no host login.
- **Process supervisor + watchdog** — `host-instance.ps1` launches Bellwright
  headless, injects UE4SS, applies the build-locked native crash guards, waits
  for the gameplay port and relaunches on crash.
- **Source Query (A2S)** — answers A2S so the server is visible to clients and
  to any server-list tool.
- **Source RCON** — standard Source RCON for remote console and admin commands.
- **Persistence** — SQLite-backed bans, scheduled tasks, and an audit log.
- **Save protection** — `HearthSaveGuard.exe` keeps a baseline of the world and
  the offline-player ledger so a bad write cannot roll a settlement back.
- **Local admin API** — a loopback-only control plane the Hearth app uses to
  start/stop, configure, and query the server.

## Run your own server

You need a Windows 10/11 or Windows Server box (no GPU required) and a copy of
Bellwright. Players connect with the free [Hearth app](https://github.com/HumanGenome/Hearth);
stock Bellwright cannot connect to a Hearth server directly.

1. **Install Bellwright on the box.** Use SteamCMD with a Steam account that
   owns the game (`+login <account> +app_update 1812450 validate`), or copy the
   `Bellwright` folder out of your own Steam library. The game files are never
   modified.
2. **Download `HearthServer-Host-Windows-x64-<tag>.zip`** from the
   [latest release](https://github.com/HumanGenome/HearthServer/releases/latest)
   and extract it somewhere outside the game folder, for example `D:\HearthHost`.
3. **Edit `HearthServer\appsettings.json`.** Set `ServerName`, `RconPassword`,
   `MaxPlayers` and the ports. Leave `GameInstallRoot` empty; the script owns
   the game process. Put your Steam64 id in `AdminSteamIds` to be able to open
   Bellwright's gameplay settings from inside the game.
4. **Start it** from an elevated PowerShell (elevation lets the script add the
   firewall rules; otherwise add them yourself):

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\host-instance.ps1 -GameRoot "D:\Bellwright"
   ```

   The first boot takes a minute or two. The script logs to `Logs\host.log`
   and prints `Bellwright host UP` once the gameplay UDP port is bound.
5. **Join** from the Hearth app with `<your ip>:<GameplayPort>`.

`.\host-instance.ps1 -Stop` stops everything; `-Restart` recycles the game
process and keeps the supervisor up. Gameplay settings (raids, spoilage, damage,
village needs and so on) live in `HearthServer\data\gameplay-settings.cfg`; a
template is written on first run, set `managed=1` to enforce it. Ports, RCON,
worlds and snapshots are covered in [docs/ADMIN.md](docs/ADMIN.md).

Several instances on one box: give each its own package folder and gameplay port
(7777, 7877, 7977, ...) and pass `-CoresPerInstance 2` so each one is pinned to
a disjoint set of cores.

Bellwright pins its engine internals per Steam build, so the signature packs,
the native patches and the gameplay-settings helper are re-derived for each
game update. A release always targets the current Steam build; after a game
patch, wait for the next release before hosting.

## Build

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).
`HearthSaveGuard.exe` is written in Rust, so building the full release payload
also needs a [Rust toolchain](https://rustup.rs/). The native host helpers
(`HearthGameplaySettings.dll`, `HearthFogReveal.dll`) are C++ built with
MinGW-w64 via CMake; the prebuilt DLLs are tracked under `dist/ue4ss-server`
and the sources under `src/native`.

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

Tagged releases (`vX.Y.Z`) build, test, publish and attach both archives
automatically via GitHub Actions, and every archive is layout-checked before
it is uploaded.

## Layout

```
src/shared/Hearth.Protocol           wire types shared with the launcher
src/shared/Hearth.Abstractions       shared interfaces
src/server/Hearth.SourceQuery        A2S responder
src/server/Hearth.Rcon               Source RCON server
src/server/Hearth.Persistence        SQLite store (bans/schedule/audit)
src/server/HearthServer              the supervisor host (entry point)
src/native/Hearth.GameplaySettings   server-authoritative gameplay settings (C++)
src/native/Hearth.FogReveal          software map-fog reveal for the headless host (C++)
src/tools/Hearth.SaveGuard           Rust save-protection helper (HearthSaveGuard.exe)
dist/ue4ss-server                    the UE4SS host layout: settings, signatures, bw_host, bw_fog
dist/engine-ini                      Engine.ini reference templates
dist/redist                          dormant WARP fallback
vendor/ue4ss                         the pinned UE4SS core (SHA-verified at release)
scripts/host-instance.ps1            the host launcher
scripts/verify-server-bundle.py      the host package layout gate
tests/                               xUnit suites for the protocol, server, and save paths
```

## What this repository ships

- `HearthServer-Host-Windows-x64-<tag>.zip` — the complete host package
  described above. This is the one to download.
- `HearthServer-Supervisor-Windows-x64-<tag>.zip` — the supervisor only
  (`HearthServer.exe`, its .NET runtime, `HearthSaveGuard.exe`), for anyone who
  already runs the host runtime and only wants the sidecar.

Neither archive contains Bellwright itself.

## Official hosting

HearthServer is officially supported by
[SurvivalServers.com](https://www.survivalservers.com/services/game_servers/bellwright/?utm_source=github&utm_medium=readme&utm_campaign=hearthserver),
which runs Bellwright servers with Hearth installed and kept on the latest
pinned release.

## License

[MIT](LICENSE) © HumanGenome
