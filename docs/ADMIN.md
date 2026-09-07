# Hearth server admin guide

Admin guide for the **complete host package** — the supervisor plus the
host-side UE4SS runtime, published as `HearthServer-Host-Windows-x64-*.zip` on
the [HearthServer release page](https://github.com/HumanGenome/HearthServer/releases/latest).
If a hosting provider runs Hearth for you, use their panel instead — these are
the raw controls.

## Server package layout

```
HearthServer\
├── HearthServer.exe          the host supervisor (RCON, query, HTTP API)
├── appsettings.json           per-instance config
ue4ss\                         host-side UE4SS layout (bw_host, bw_fog, signatures)
engine-ini\                    Engine.ini host/client reference templates
redist\                        dormant WARP fallback
host-instance.ps1              the host launcher (stage, launch, patch, supervise)
steam_appid.txt
```

## Settings (`HearthServer\appsettings.json`)

The `Hearth` block carries the per-instance config. At minimum set:

- `InstanceId` — a stable id for this instance
- `GameplayPort` / query / RCON / HTTP ports (see ports below)
- `RconPassword` — required to use RCON
- `ServerName` — shown in the server query / browser
- `AdminSteamIds` — Steam64 IDs allowed to open Bellwright's native gameplay
  settings. The player must add the server through its owner/admin link or save
  the matching RCON password in Hearth; Steam64 alone never grants authority.
  Hearth validates the one-use launcher ticket against Bellwright's accepted
  connection before the host grants the native settings permission.

`Mods` settings nest **under** the `Hearth` block, not at the top level.

## Ports

| Offset | Default | Purpose | Proto |
|--------|---------|---------|-------|
| +0 | 7777 | Gameplay (the join port) | UDP |
| +1 | 7778 | Control / IPC identifier (local only) | — |
| +2 | 7779 | Server query (A2S) | UDP |
| +3 | 7780 | RCON | TCP |
| +4 | 7781 | Admin HTTP API | TCP |

Open/forward each externally-reachable port (+0, +2, +3, +4). The control port
(+1) is a local IPC identifier and needs no firewall rule. The gameplay UDP
port in particular needs a Windows Defender inbound allow rule, or players can't
reach the listen socket.

## RCON commands

HearthServer exposes Source RCON on the RCON port:

- `help` — list commands
- `status` — server status
- `players` — connected players
- `ping` — liveness
- `save snapshot` — take a world snapshot
- `save list` — list saved worlds
- `save restore <id>` — roll the world back to a snapshot

## Worlds and characters

A character is bound to the Steam account that created it. The client joins with
`?Name=steam_<steamid64>` as the login identity and carries the typed display
name separately, so Bellwright resolves the persistent player from the Steam
identity. The name field in the launcher is a display name, not a character
picker, and there is no supported way to reassign a saved character to a
different Steam account.

Importing another server's world brings the world with it — buildings,
settlements, map progress. The characters inside it stay bound to their original
Steam64 IDs, so a new player joins that world as a new character.

To move a world, take a snapshot on the source (`save snapshot`), download it
(`GET /api/v1/snapshots/<id>/download`), and swap it in on the destination with
`POST /api/v1/snapshots/import-restore`. Do not copy save files in directly:
restore clears the world-protection baseline and offline-player ledger as part
of the swap, and a direct file copy leaves the previous baseline in place, so
protection can read the import as a regression and roll it back.

## Server query

HearthServer answers Source A2S on the query port, so any standard server-list
tool, monitor, or bot can read status and player count.

## Running

Use `host-instance.ps1` to launch. It reads `HearthServer\appsettings.json`,
stages UE4SS beside the game, emits the per-instance Engine.ini, starts the
supervisor, launches Bellwright headless with `-nullrhi`, injects UE4SS, applies
the build-locked native patches, waits for the gameplay port to bind and then
supervises the process. `-Stop` and `-Restart` signal a running instance.
Pass `-CoresPerInstance N` to pin each instance to a disjoint set of cores when
running several on one box. The repository README has the step-by-step guide.
