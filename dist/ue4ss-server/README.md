# dist/ue4ss-server — Bellwright host-side UE4SS layout

This is the UE4SS layout that ships inside the Hearth host server package and is
installed alongside Bellwright (Steam 1812450, UE5.7.4 "Mist") on the host
machine. It is what makes a Bellwright process come up as a direct-IP listen
server instead of a normal Steam-P2P client.

**Deploy mapping:** the host package places THIS directory's contents at
`ue4ss/` under the package root (so `dist/ue4ss-server/Mods/bw_host` becomes
`ue4ss\Mods\bw_host`), and `host-instance.ps1` stages that tree beside the
game exe on every launch. The CLIENT connect mod (`HearthConnect`) lives in the
separate `dist/ue4ss-client/` pack players install on their own PC.

## What it does (proven 2026-06-14)

`bw_host` (from the LoopAsync async thread — tick/engine detours FAIL on 5.7.4):
1. Swaps `NetDriverDefinitions[GameNetDriver]` from `SteamSockets.SteamSocketsNetDriver`
   to stock `OnlineSubsystemUtils.IpNetDriver`.
2. `OpenLevel(GameInstance, <world>, listen?Port=<port>)` where `<world>` is the
   `NewGameMapName` reflection prop (stock = `Karvenia_08`) unless overridden.

A second IpNetDriver client firing `open <ip>:<port>` was Welcomed into the real
world over direct IP — host-accept → Join succeeded, no Steam / no EOS.
**Bellwright needs NO native host patch.** (Contrast Grounded 2's LanternHostPatch.)

## Layout

```
ue4ss-server/
├── UE4SS.dll                 (vendored official b50986bd core; SHA-pinned at release)
├── UE4SS-settings.ini        (MajorVersion=5 MinorVersion=7, UseCache off while sigs settle)
├── UE4SS_Signatures/         (5 AOB sigs derived from this build's PDB — all resolve live)
│   ├── FName_Constructor.lua
│   ├── GNatives.lua
│   ├── GUObjectArray.lua
│   ├── GUObjectHashTables.lua
│   └── StaticConstructObject.lua
└── Mods/
    ├── mods.txt              (bw_host : 1)
    └── bw_host/Scripts/main.lua
```

`bw_host` v0.18.29 or newer requires the official b50986bd core. Its
invalid-field sentinel and `IsValidField` API keep optional UObject probes from
dereferencing missing fields while Bellwright tears objects down during GC.

## Launcher inputs (host-instance.ps1 sets these)

- `HEARTH_GAME_PORT`  — gameplay UDP port (per-instance; falls back to 7777).
- `HEARTH_WORLD_NAME` — world map to host (falls back to NewGameMapName → ServerDefaultMap).
- `HEARTH_HOST_LOG`   — log path for the mod.
- `HEARTH_ADMIN_STEAM_IDS` — comma-separated Steam64 IDs eligible for Bellwright's
  replicated host-player authority.
- `HEARTH_ADMIN_TICKET_FILE` — server-local one-use ticket registry. Authority is
  granted only when a configured ID presents a current RCON-authenticated ticket.
- `HEARTH_MAX_PLAYERS` — player slots advertised and enforced (the hidden listen
  host takes one extra native seat on top).
- `HEARTH_GAMEPLAY_SETTINGS_FILE` / `_STATUS` — the managed gameplay-settings
  document and the status file the native applier writes back.
