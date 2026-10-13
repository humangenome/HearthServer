<p align="center">
  <img src="https://raw.githubusercontent.com/HumanGenome/Hearth/main/docs/img/hearth-lockup-dark.png" alt="Hearth" width="420">
</p>

<p align="center">
  <a href="#requirements"><img src="https://img.shields.io/badge/Platform-Windows_10%2F11%2FServer-blue.svg" alt="Platform"></a>
  <a href="https://store.steampowered.com/app/1812450/"><img src="https://img.shields.io/badge/Game-Bellwright-darkgreen.svg" alt="Game"></a>
  <a href="https://github.com/HumanGenome/Hearth"><img src="https://img.shields.io/badge/Player_App-Hearth-brightgreen.svg" alt="Player app"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey.svg" alt="License"></a>
</p>

# HearthServer

[Bellwright](https://store.steampowered.com/app/1812450/) has no dedicated server. Its multiplayer is co-op for up to four people, hosted from one player's copy of the game. HearthServer adds a Bellwright dedicated server: it runs the game headless on a Windows machine with a public IP and port, and players join it by address through the [Hearth app](https://github.com/HumanGenome/Hearth). This repo is for the person running the server; players only need the app.

This is the whole server side: the supervisor, the host mods (`bw_host`, `bw_fog`, `bw_seat4`), their native helpers, the signature packs and the launch script. The player app is closed source.

## What it does

- Runs Bellwright with no GPU, no screen and no Steam login, and takes direct connections on a UDP port
- A fourth player place: the game counts its own host as one of its four places and sends world data to only three joiners; the host package frees the hidden host's place and sends a fourth player that data
- Ties each character to the player's Steam account, not to the name typed in the app, and leaves a player who drops to the game's own rejoin handling instead of freezing their character
- Protects the world on disk: every autosave is checked, a player record the game drops while that player is offline is put back, a save rotation that slides back to a starter world is repaired before launch, and a save left as zeros by a power loss is replaced by the newest intact copy
- Applies the game's 21 gameplay settings (raids, spoilage, damage, village needs and the rest) from a text file through the game's own setters, because the in-game menu cannot save them on a dedicated host
- Writes each player's map exploration into the world, which the game only does on a machine that renders, and keeps Travel Signs linked
- Build-locked crash guards for the current Bellwright build (quest rewards, map icons, harvesting, roads, the build menu), applied at launch and checked byte for byte
- Source RCON with `say`, `announce`, `motd`, player list and world snapshots; snapshot download and restore over a signed HTTP API
- Answers Source server query, so server lists, monitors and bots see the name, map and player count
- Bans, the restart schedule and an admin audit log, kept in SQLite across restarts
- A supervisor that relaunches the game if it crashes, and `-Stop` / `-Restart` switches that ask the game to save first

## What it does not do

- **It does not ship Bellwright.** You install the game files yourself from a Steam account that owns the game.
- **It does not replace the player's game.** Everyone joining runs retail Bellwright with the Hearth app on top. Stock Bellwright cannot connect to a Hearth server.
- **It does not follow a game update by itself.** Bellwright pins its engine internals per Steam build, so the signature packs, the native patches and the gameplay-settings helper are re-derived for each game patch. After a patch, wait for the next release before hosting.

## Requirements

| | |
|---|---|
| OS | Windows 10, Windows 11 or Windows Server |
| Game files | A Bellwright installation on the host from your own Steam copy (about 23 GB) |
| Ports | One UDP port for gameplay and one for server query, two TCP ports for RCON and the admin API |
| Hardware | No GPU. Plan on 3 to 4 GB of RAM and one to two CPU cores per server; the game simulates its villages whether or not anyone is online |

## Ports

| Port | Protocol | Used for |
|---|---|---|
| base (default `7777`) | UDP | Gameplay, the port players connect to |
| base + 2 (default `7779`) | UDP | Server query (Source A2S) |
| base + 3 (default `7780`) | TCP | Source RCON |
| base + 4 (default `7781`) | TCP | Admin HTTP API (snapshots, players) |

Open the two UDP ports on the host firewall and forward them if the server sits behind NAT. Open the TCP ports only for the people who should reach them. `base + 1` is a local name, not a listening port.

## Setup

1. **Install Bellwright on the host.** Use SteamCMD with an account that owns the game (`+login <account> +app_update 1812450 validate`), or copy the `Bellwright` folder from your own Steam library. The game files are never modified.
2. **Download `HearthServer-Host-Windows-x64-<version>.zip`** from the [latest release](https://github.com/HumanGenome/HearthServer/releases/latest) and extract it outside the game folder, for example `D:\HearthHost`.
3. **Edit `HearthServer\appsettings.json`.** Set `ServerName`, `RconPassword`, `MaxPlayers` (up to 4) and the ports. Leave `GameInstallRoot` empty; the launch script owns the game process.
4. **Start it** from an elevated PowerShell (elevation lets the script add the firewall rules; otherwise add them yourself):

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\host-instance.ps1 -GameRoot "D:\Bellwright"
   ```

   The first boot takes a minute or two. The script logs to `Logs\host.log` and prints `Bellwright host UP` once the gameplay port is bound.
5. **Hand players the address** as `ip:port`. They add it in the Hearth app and press Connect.

`.\host-instance.ps1 -Stop` asks the game to save, then stops everything; `-Restart` does the same for the game alone and keeps the supervisor up. Gameplay settings live in `HearthServer\data\gameplay-settings.cfg`: a template is written on the first start, and `managed=1` makes the server enforce it. RCON, worlds, snapshots and admin details are in [docs/ADMIN.md](docs/ADMIN.md).

Several servers on one machine: give each its own package folder and gameplay port (7777, 7877, 7977 and so on) and pass `-CoresPerInstance 2` so each one runs on its own cores.

## Build

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0). `HearthSaveGuard.exe` is written in Rust, so the full release payload also needs a [Rust toolchain](https://rustup.rs/). The native host helpers (`HearthGameplaySettings.dll`, `HearthFogReveal.dll`, `HearthFourthSeat.dll`) are C++ built with MinGW-w64 through CMake; the prebuilt DLLs are tracked under `dist/ue4ss-server` and the sources under `src/native`.

```bash
dotnet restore HearthServer.sln
dotnet build HearthServer.sln -c Release
dotnet test  HearthServer.sln -c Release
cargo test --manifest-path src/tools/Hearth.SaveGuard/Cargo.toml --release
lua5.4 tests/host-seat-count.test.lua   # also host-login-identity and host-spline-replication
```

Tagged releases (`vX.Y.Z`) build, test and attach both archives through GitHub Actions, and every archive is layout-checked before upload.

## Layout

```
src/server/HearthServer              the supervisor (entry point)
src/server/Hearth.SourceQuery        A2S responder
src/server/Hearth.Rcon               Source RCON server
src/server/Hearth.Persistence        SQLite store (bans, schedule, audit)
src/shared/Hearth.Protocol           wire types shared with the player app
src/shared/Hearth.Abstractions       shared interfaces
src/native/Hearth.GameplaySettings   server-side gameplay settings (C++)
src/native/Hearth.FogReveal          map exploration on a host with no screen (C++)
src/native/Hearth.FourthSeat         world data for the fourth player (C++)
src/tools/Hearth.SaveGuard           save protection (Rust, HearthSaveGuard.exe)
dist/ue4ss-server                    the UE4SS host layout: settings, signatures, bw_host, bw_fog, bw_seat4
dist/engine-ini                      Engine.ini reference templates
vendor/ue4ss                         the pinned UE4SS core (checked by hash at release)
scripts/host-instance.ps1            the launch script
scripts/verify-server-bundle.py      the host package layout check
tests/                               .NET suites and the host-mod checks
```

## Releases

- `HearthServer-Host-Windows-x64-<version>.zip` is the complete host package described above. This is the one to download.
- `HearthServer-Supervisor-Windows-x64-<version>.zip` is the supervisor alone (`HearthServer.exe`, its .NET runtime and `HearthSaveGuard.exe`) for anyone who already runs the host runtime.

Neither archive contains Bellwright. The player app is published on [HumanGenome/Hearth](https://github.com/HumanGenome/Hearth).

## Hosting

[SurvivalServers.com](https://www.survivalservers.com/services/game_servers/bellwright/?utm_source=github&utm_medium=readme&utm_campaign=hearthserver) runs Bellwright servers with HearthServer installed.

## Community Note

HearthServer is a community project and is not affiliated with or endorsed by the developers of Bellwright.

## License

[MIT](LICENSE)
