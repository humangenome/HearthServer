#!/usr/bin/env python3
"""Verify a Hearth complete host package before it is published or pinned.

The host package is the artifact that can actually run a joinable server: the
.NET supervisor under `HearthServer/` PLUS the UE4SS runtime, the PDB-derived
signatures, the `bw_host` host mod, the Engine.ini templates, the WARP redist
and the host launch helper.

A zip carrying only the supervisor publish output is a valid, internally
consistent, correctly checksummed zip -- and a host nobody can join. The
supervisor comes up, Bellwright starts, and it never swaps to `IpNetDriver`,
so no client can connect. That archive is a real product on the public release
line (see the README), but it is a DIFFERENT artifact with a DIFFERENT name.
Publishing it under this one's name is the defect this guard exists to stop.

    python scripts/verify-server-bundle.py <package.zip>

Exit 0 only when the zip is a complete host package. Any other outcome exits 1,
including anything this script cannot positively confirm.

Assert LAYOUT, not size and not a checksum. Every artifact that shipped wrong
was internally consistent and correctly checksummed; it was simply the wrong
thing, and a hash comparison between two copies of the wrong file passes
happily. A size floor is a weak proxy at best -- on a sibling project the
correct package was SMALLER than the broken one.
"""

import argparse
import os
import sys
import zipfile

# Every one of these must be present and non-empty.
REQUIRED_ENTRIES = (
    "HearthServer/HearthServer.exe",
    "HearthServer/HearthServer.dll",
    "HearthServer/HearthServer.runtimeconfig.json",
    "HearthServer/HearthSaveGuard.exe",
    "HearthServer/appsettings.json",
    "ue4ss/UE4SS.dll",
    "ue4ss/UE4SS-settings.ini",
    "ue4ss/Mods/mods.txt",
    "ue4ss/Mods/bw_host/HearthGameplaySettings.dll",
    "ue4ss/Mods/bw_host/Scripts/main.lua",
    # bw_fog: the software map-fog reveal (isolated mod, switched on in mods.txt).
    "ue4ss/Mods/bw_fog/HearthFogReveal.dll",
    "ue4ss/Mods/bw_fog/Scripts/main.lua",
    # The 5 PDB-derived AOB signatures are mandatory on UE5.7. Without them
    # UE4SS falls back to its built-in scanner, hits the GUObjectArray trap and
    # hangs at "Waiting for object construction".
    "ue4ss/UE4SS_Signatures/FName_Constructor.lua",
    "ue4ss/UE4SS_Signatures/GNatives.lua",
    "ue4ss/UE4SS_Signatures/GUObjectArray.lua",
    "ue4ss/UE4SS_Signatures/GUObjectHashTables.lua",
    "ue4ss/UE4SS_Signatures/StaticConstructObject.lua",
    "engine-ini/Engine.host.ini",
    "engine-ini/Engine.client.ini",
    "redist/d3d10warp.dll",
    "steam_appid.txt",
    "host-instance.ps1",
)

# UE4SS.dll is ~16 MB. A truncated or placeholder file is not a runtime.
MIN_UE4SS_DLL_BYTES = 1_000_000

# The host mod is ~148 KB of Lua. A stub is not a host mod.
MIN_HOST_MOD_BYTES = 20_000

# The gameplay-settings helper is a statically linked x64 native DLL. A missing,
# truncated or wrong-architecture helper makes managed settings fail closed.
MIN_GAMEPLAY_SETTINGS_DLL_BYTES = 100_000

# The WARP redist is ~8.5 MB; the in-box Windows d3d10warp.dll fails UE5's SM6
# check on a no-GPU host, so a placeholder here is a dead host.
MIN_WARP_BYTES = 1_000_000

# The launch helper is ~15 KB of PowerShell.
MIN_HOST_SCRIPT_BYTES = 2_000

# The self-contained supervisor publish output is ~350 files.
MIN_SUPERVISOR_ENTRIES = 300

# Publish output at the zip root is the signature of a supervisor-only artifact.
FLAT_ROOT_MARKERS = (
    "hearthserver.exe",
    "hearthserver.dll",
    "hearthsaveguard.exe",
    "hostfxr.dll",
    "coreclr.dll",
)


def normalise(name):
    return name.replace("\\", "/").lstrip("./")


def enabled_mods(text):
    """Parse a UE4SS Mods/mods.txt -> the names with a trailing ': 1'."""
    names = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        name, _, state = line.partition(":")
        if state.strip() == "1":
            names.append(name.strip())
    return names


def verify(path):
    failures = []

    if not os.path.isfile(path):
        return ["not a file: {}".format(path)]

    try:
        zf = zipfile.ZipFile(path)
    except Exception as exc:  # noqa: BLE001 - fail closed on anything
        return ["cannot open as a zip: {}".format(exc)]

    with zf:
        bad = zf.testzip()
        if bad is not None:
            failures.append("corrupt entry: {}".format(bad))

        sizes = {}
        for info in zf.infolist():
            name = normalise(info.filename)
            if name.endswith("/"):
                continue
            sizes[name.lower()] = info.file_size

        for entry in REQUIRED_ENTRIES:
            key = entry.lower()
            if key not in sizes:
                failures.append("missing required entry: {}".format(entry))
            elif sizes[key] == 0:
                failures.append("required entry is empty: {}".format(entry))

        for marker in FLAT_ROOT_MARKERS:
            if marker in sizes:
                failures.append(
                    "'{}' sits at the zip root -- this is the supervisor archive, "
                    "not the complete host package (the supervisor belongs under "
                    "HearthServer/)".format(marker)
                )

        floors = (
            ("ue4ss/ue4ss.dll", "UE4SS.dll", MIN_UE4SS_DLL_BYTES),
            ("ue4ss/mods/bw_host/scripts/main.lua", "bw_host main.lua",
             MIN_HOST_MOD_BYTES),
            ("ue4ss/mods/bw_host/hearthgameplaysettings.dll",
             "HearthGameplaySettings.dll", MIN_GAMEPLAY_SETTINGS_DLL_BYTES),
            ("ue4ss/mods/bw_fog/hearthfogreveal.dll",
             "HearthFogReveal.dll", MIN_GAMEPLAY_SETTINGS_DLL_BYTES),
            ("redist/d3d10warp.dll", "redist/d3d10warp.dll", MIN_WARP_BYTES),
            ("host-instance.ps1", "host-instance.ps1", MIN_HOST_SCRIPT_BYTES),
        )
        for key, label, floor in floors:
            got = sizes.get(key)
            if got is not None and got < floor:
                failures.append(
                    "{} is {:,} bytes, below the {:,} byte floor".format(
                        label, got, floor
                    )
                )

        supervisor = [n for n in sizes if n.startswith("hearthserver/")]
        if len(supervisor) < MIN_SUPERVISOR_ENTRIES:
            failures.append(
                "only {} files under HearthServer/ (expected at least {}) -- the "
                "supervisor publish output is incomplete".format(
                    len(supervisor), MIN_SUPERVISOR_ENTRIES
                )
            )

        # Anything mods.txt switches on has to actually be in the zip, or UE4SS
        # boots with a mod list that references nothing.
        try:
            manifest = zf.read("ue4ss/Mods/mods.txt").decode("utf-8-sig", "replace")
        except KeyError:
            manifest = None
        except Exception as exc:  # noqa: BLE001
            manifest = None
            failures.append("cannot read ue4ss/Mods/mods.txt: {}".format(exc))
        if manifest:
            enabled = enabled_mods(manifest)
            if not enabled:
                failures.append("ue4ss/Mods/mods.txt enables no mods at all")
            for mod in enabled:
                key = "ue4ss/mods/{}/scripts/main.lua".format(mod.lower())
                if key not in sizes:
                    failures.append(
                        "mods.txt enables '{}' but the zip has no "
                        "ue4ss/Mods/{}/Scripts/main.lua".format(mod, mod)
                    )

    return failures


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", help="path to the complete host package zip")
    args = parser.parse_args(argv)

    try:
        failures = verify(args.zip)
    except Exception as exc:  # noqa: BLE001 - never pass on an unexpected error
        print("FAIL {}: unexpected error: {}".format(args.zip, exc))
        return 1

    if failures:
        print("FAIL {} is not a complete Hearth host package:".format(args.zip))
        for line in failures:
            print("  - {}".format(line))
        print(
            "\nDo not publish or pin this artifact. The complete host package "
            "carries the UE4SS runtime, the signatures and the bw_host mod "
            "alongside the supervisor. Without them the host never swaps to "
            "IpNetDriver and no client can connect."
        )
        return 1

    print(
        "OK {} is a complete host package ({:,} bytes)".format(
            args.zip, os.path.getsize(args.zip)
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
