# Hearth server admin guide

Admin guide for the **complete host package**: the supervisor plus the host-side UE4SS runtime, published as `HearthServer-Host-Windows-x64-*.zip` on the [HearthServer release page](https://github.com/HumanGenome/HearthServer/releases/latest). If a hosting provider runs Hearth for you, use their panel instead; these are the raw controls.

## Server package layout

```
HearthServer\
├── HearthServer.exe          the host supervisor (RCON, query, HTTP API)
├── appsettings.json           per-instance config
ue4ss\                         host-side UE4SS layout (bw_host, bw_fog, bw_seat4, signatures)
engine-ini\                    Engine.ini host/client reference templates
redist\                        dormant WARP fallback
host-instance.ps1              the host launcher (stage, launch, patch, supervise)
steam_appid.txt
```

## Settings (`HearthServer\appsettings.json`)

The `Hearth` block carries the per-instance config. At minimum set:

- `InstanceId`: a stable id for this instance
- `GameplayPort` and the query, RCON and HTTP ports (see ports below)
- `RconPassword`: required for RCON and the admin API
- `ServerName`: shown in server query and server lists
- `MaxPlayers`: up to 4, the game's own limit
- `AdminSteamIds`: Steam64 IDs that get the game's host flag in the world, the one Bellwright normally gives the player who hosts. The player must also prove the admin password: they add the server through its admin link or save the matching RCON password in Hearth. A Steam64 alone never grants it; HearthServer checks a one-use ticket from the app against the connection Bellwright accepted before the host sets the flag.

Gameplay settings (raids, spoilage, damage, village needs and the rest of the game's 21 settings) are not changed from the in-game menu on a dedicated host: Bellwright only saves that menu on the machine that hosts. Set them in `HearthServer\data\gameplay-settings.cfg` instead. The launch script writes a template on the first start; set `managed=1` and the server applies the file through the game's own setters on every start.

`Mods` settings nest **under** the `Hearth` block, not at the top level.

## Ports

| Offset | Default | Purpose | Proto |
|--------|---------|---------|-------|
| +0 | 7777 | Gameplay (the join port) | UDP |
| +1 | 7778 | Control / IPC identifier (local only) | none |
| +2 | 7779 | Server query (A2S) | UDP |
| +3 | 7780 | RCON | TCP |
| +4 | 7781 | Admin HTTP API | TCP |

Open and forward the gameplay and query ports (+0, +2). Open the RCON and HTTP ports (+3, +4) only for the people who should reach them. The control port (+1) is a local name and needs no firewall rule. The gameplay UDP port needs a Windows Defender inbound allow rule, or players cannot reach the server; the launch script adds the rules when it runs elevated.

## RCON commands

HearthServer exposes Source RCON on the RCON port:

- `help`: list commands
- `status`: server status
- `players`: connected players
- `ping`: liveness
- `say <text>` and `announce <text>`: send a message to the server's chat channel
- `motd <text>`: set the message of the day
- `save snapshot`: take a world snapshot
- `save list`: list saved snapshots
- `save restore <id>`: roll the world back to a snapshot

## Worlds and characters

A character is bound to the Steam account that created it. The client joins with `?Name=steam_<steamid64>` as the login identity and carries the typed display name separately, so Bellwright resolves the persistent player from the Steam identity. The name field in the app is a display name, not a character picker, and there is no supported way to reassign a saved character to a different Steam account.

Importing another server's world brings the world with it: buildings, settlements, map progress. The characters inside it stay bound to their original Steam64 IDs, so a new player joins that world as a new character.

To move a world, take a snapshot on the source (`save snapshot`), download it (`GET /api/v1/snapshots/<id>/download`), and swap it in on the destination with `POST /api/v1/snapshots/import-restore`. Do not copy save files in directly: restore clears the world-protection baseline and offline-player ledger as part of the swap, and a direct file copy leaves the previous baseline in place, so protection can read the import as a regression and roll it back.

## Server query

HearthServer answers Source A2S on the query port, so any standard server-list tool, monitor or bot can read status and player count.

## Running

Use `host-instance.ps1` to launch. It reads `HearthServer\appsettings.json`, checks the save, stages UE4SS beside the game, emits the per-instance Engine.ini, starts the supervisor, launches Bellwright headless with `-nullrhi`, injects UE4SS, applies the build-locked native patches, waits for the gameplay port to bind and then supervises the process, relaunching the game if it exits.

`-Stop` and `-Restart` signal a running instance. Both ask the game to save the world first and wait up to 20 seconds for the save to land before the game is closed; `Logs\host.log` says `save before stop: confirmed` when it landed. The game sometimes skips a save requested right after its own autosave (it autosaves about every two minutes), so at most the last couple of minutes can be lost. If the host mod reports that it cannot run work on the game thread (its heartbeat in `Logs\bw_host.log` ends `,stalled`), the requested save cannot happen, so the stop waits instead for the game's own next autosave when it is due within 150 seconds (`save before stop: host helper stalled, ...` in `Logs\host.log`). Pass `-CoresPerInstance N` to pin each instance to its own set of cores when running several on one machine. The repository README has the step-by-step guide.

### When a start refuses

Before every launch the save guard checks `UserDir\Saved\SaveGames\TEMP_auto.sav`. If a power loss left that file as zeros, the newest intact copy among the other save slots and the protected baseline takes its place, and the torn file is kept beside it as `TEMP_auto.sav.torn-<time>`. Any other save the guard cannot read stops the start with a plain error in `Logs\host.log`, so a world is never replaced by an older copy without a reason.
