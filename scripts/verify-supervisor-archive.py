#!/usr/bin/env python3
"""Verify the archive this repository publishes is exactly what it claims to be.

This repository builds the SUPERVISOR ONLY. That is a deliberate product
decision, not an accident: the host-side UE4SS runtime is not published, so the
archive here supervises Bellwright but cannot produce a joinable server. The
README says so plainly and it must keep saying so.

The defect this guard exists to stop is the NAME, not the contents. For 73
published releases this archive went out as `Hearth-Server-Windows-x64-<tag>.zip`
-- the same asset name the complete host package uses on the private release
line -- so a self-hoster who followed the download instructions got a supervisor
and a server no one could join. The archive is now named
`HearthServer-Supervisor-Windows-x64-<tag>.zip`, and this check refuses to let
it drift back.

It also fails if the host runtime ever appears in here. A `ue4ss/` tree in this
archive means the unpublished host mod leaked into a public artifact.

    python3 scripts/verify-supervisor-archive.py <archive.zip>

Exit 0 only when the archive is the supervisor, correctly named. Any other
outcome exits 1, including anything this script cannot positively confirm.

Assert LAYOUT and NAME. Not size, and not a checksum -- a correctly checksummed
archive of the wrong thing under the wrong name is exactly the failure here.
"""

import argparse
import os
import re
import sys
import zipfile

# The archive is the flat `dotnet publish` output plus the save guard.
REQUIRED_ENTRIES = (
    "HearthServer.exe",
    "HearthServer.dll",
    "HearthServer.runtimeconfig.json",
    "HearthSaveGuard.exe",
    "appsettings.json",
    "hostfxr.dll",
    "coreclr.dll",
)

# Anything under these prefixes belongs to the complete host package and must
# never be published from this repository.
FORBIDDEN_PREFIXES = (
    "ue4ss/",
    "hearthserver/",
    "engine-ini/",
    "redist/",
)

FORBIDDEN_ENTRIES = (
    "host-instance.ps1",
    "steam_appid.txt",
)

MIN_ENTRIES = 300

NAME_RE = re.compile(r"^HearthServer-Supervisor-Windows-x64-v\d+\.\d+\.\d+.*\.zip$")


def normalise(name):
    return name.replace("\\", "/").lstrip("./")


def verify(path):
    failures = []

    if not os.path.isfile(path):
        return ["not a file: {}".format(path)]

    base = os.path.basename(path)
    if not NAME_RE.match(base):
        failures.append(
            "'{}' is not named HearthServer-Supervisor-Windows-x64-<tag>.zip -- "
            "this archive is the supervisor and its name has to say so. The "
            "complete host package name belongs to a different artifact.".format(base)
        )

    try:
        zf = zipfile.ZipFile(path)
    except Exception as exc:  # noqa: BLE001 - fail closed on anything
        return failures + ["cannot open as a zip: {}".format(exc)]

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

        for name in sizes:
            for prefix in FORBIDDEN_PREFIXES:
                if name.startswith(prefix):
                    failures.append(
                        "'{}' belongs to the complete host package and must not "
                        "be published from this repository".format(name)
                    )
                    break
        for entry in FORBIDDEN_ENTRIES:
            if entry.lower() in sizes:
                failures.append(
                    "'{}' belongs to the complete host package and must not be "
                    "published from this repository".format(entry)
                )

        if len(sizes) < MIN_ENTRIES:
            failures.append(
                "only {} files in the archive (expected at least {}) -- the "
                "publish output is incomplete".format(len(sizes), MIN_ENTRIES)
            )

    return failures


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", help="path to the supervisor archive zip")
    args = parser.parse_args(argv)

    try:
        failures = verify(args.zip)
    except Exception as exc:  # noqa: BLE001 - never pass on an unexpected error
        print("FAIL {}: unexpected error: {}".format(args.zip, exc))
        return 1

    if failures:
        print("FAIL {} is not a correctly named supervisor archive:".format(args.zip))
        for line in failures:
            print("  - {}".format(line))
        print(
            "\nDo not publish this artifact. This repository publishes the "
            "supervisor under its own name. An archive that carries the host "
            "runtime, or that borrows the complete host package's name, sends "
            "self-hosters somewhere the README does not."
        )
        return 1

    print(
        "OK {} is the supervisor archive, correctly named ({:,} bytes)".format(
            args.zip, os.path.getsize(args.zip)
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
