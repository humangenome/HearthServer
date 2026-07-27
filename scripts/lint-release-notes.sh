#!/usr/bin/env bash
# Enforce the release-note shape before a release publishes.
#
# 79 published Hearth release bodies in a row broke the standard: every one
# repeated a version header GitHub already renders, none used the `---` + single
# hosting line, and the Server/Client grouping was used around v0.1.46-v0.1.51
# and then dropped. Nothing checked, so nothing held. This is the check.
#
# Usage:
#   scripts/lint-release-notes.sh .github/release-notes/v0.1.85.md
#   scripts/lint-release-notes.sh --profile body release-body.md
#   scripts/lint-release-notes.sh --all
#
# Profiles:
#   notes  (default) Hand-written release-note files. Full standard.
#   body             A generated body (the HearthServer workflow builds its own
#                    from CHANGELOG.md). Component grouping and one-line bullets
#                    are not required; the header, footer, link and language
#                    rules still are.

set -euo pipefail

PROFILE="notes"
FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --all)
      REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
      while IFS= read -r f; do FILES+=("$f"); done < <(find "$REPO_ROOT/.github/release-notes" -name 'v*.md' | sort)
      shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "usage: $0 [--profile notes|body] <file>... | --all" >&2
  exit 2
fi

python3 - "$PROFILE" "${FILES[@]}" <<'PY'
import re
import sys
from pathlib import Path

profile, *paths = sys.argv[1:]

COMPONENTS = ("Server", "Client")
# One optional trailing section, for saying plainly what each archive contains.
TRAILING_SECTIONS = ("Downloads",)
CHANGE_TYPES = ["Added", "Changed", "Fixed", "Removed"]
HOSTING_PATH = "survivalservers.com/services/game_servers/bellwright/"
FOOTER_RE = re.compile(
    r"^Hosting: \[SurvivalServers\.com\]\((?P<url>https://[^)]+)\) runs Hearth for you\.$"
)
VERSION_HEADER_RE = re.compile(
    r"^#{1,4}\s*(\[?v?\d+\.\d+\.\d+|(Hearth|HearthServer)\s+v?\d+\.\d+)", re.IGNORECASE
)
BANNED = [
    "game-changing", "game changing", "revolutionary", "banger", "blazing",
    "the big one", "way better", "seamlessly", "delve into", "in today's",
    "we're excited", "we are excited", "supercharge", "next-level",
    "servers pick this up on their next restart",
    "is the official hosting partner",
    "official hosting",
    "control panel", "scheduled restarts",
]

total_failures = 0

for path in paths:
    p = Path(path)
    problems = []
    text = p.read_text(encoding="utf-8")
    lines = text.rstrip("\n").split("\n")

    if not text.strip():
        problems.append("file is empty")
        lines = []

    lowered = text.lower()
    for phrase in BANNED:
        if phrase in lowered:
            problems.append(f"banned phrase: {phrase!r}")

    # --- headers -----------------------------------------------------------
    headings = [(i, l) for i, l in enumerate(lines) if l.startswith("#")]
    for i, l in headings:
        if VERSION_HEADER_RE.match(l):
            problems.append(
                f"line {i+1}: repeated version header {l.strip()!r} — GitHub already "
                f"renders the version and date above the body"
            )
        if l.startswith("# "):
            problems.append(f"line {i+1}: top-level '# ' heading {l.strip()!r}; sections start at '##'")

    # --- footer ------------------------------------------------------------
    tail = [l for l in lines if l.strip()]
    if len(tail) < 2:
        problems.append("no hosting footer")
    else:
        rule, footer = tail[-2], tail[-1]
        m = FOOTER_RE.match(footer)
        if not m:
            problems.append(
                "last line must be exactly: "
                "Hosting: [SurvivalServers.com](<utm link>) runs Hearth for you."
                f"  (found: {footer.strip()!r})"
            )
        else:
            url = m.group("url")
            if HOSTING_PATH not in url:
                problems.append(
                    f"hosting link must point at {HOSTING_PATH} (found {url}); "
                    f"the /games/bellwright/ path 404s"
                )
            if "utm_source=github" not in url:
                problems.append("hosting link is missing its utm_source=github tag")
        if rule.strip() != "---":
            problems.append(
                f"the hosting footer must be preceded by a '---' rule (found {rule.strip()!r})"
            )
        if lines and lines[-1].strip() == "":
            pass  # trailing newline is fine
        elif tail[-1] != [l for l in lines if l.strip()][-1]:
            problems.append("content after the hosting footer")

    # --- structure (strict profile only) -----------------------------------
    if profile == "notes":
        component_headings = [
            (i, l[3:].strip()) for i, l in headings if l.startswith("## ")
        ]
        comps = [(i, name) for i, name in component_headings if name in COMPONENTS]
        if not comps:
            problems.append(
                "no component section — the body must group changes under "
                "'## Server' and/or '## Client'"
            )
        extra = [
            (i, name) for i, name in component_headings
            if name not in COMPONENTS and name not in TRAILING_SECTIONS
        ]
        if comps and extra:
            first_comp = comps[0][0]
            for i, name in extra:
                if i > first_comp:
                    problems.append(
                        f"line {i+1}: '## {name}' is not a component section and comes "
                        f"after the component grouping"
                    )
            if len(extra) > 1:
                problems.append(
                    "at most one feature headline is allowed above the component sections"
                )
        seen = set()
        for i, name in comps:
            if name in seen:
                problems.append(f"line {i+1}: duplicate '## {name}' section")
            seen.add(name)

        # change-type subheadings, per component. A trailing section ends the
        # last component, so it bounds the final slice.
        trailing = [i for i, name in component_headings if name in TRAILING_SECTIONS]
        if trailing and comps and min(trailing) < max(i for i, _ in comps):
            problems.append(
                f"line {min(trailing)+1}: "
                f"{'/'.join(TRAILING_SECTIONS)} must come after every component section"
            )
        bounds = [i for i, _ in comps] + [min(trailing) if trailing else len(lines)]
        for idx, (start, name) in enumerate(comps):
            end = bounds[idx + 1]
            body = lines[start + 1:end]
            subs = [l[4:].strip() for l in body if l.startswith("### ")]
            for s in subs:
                if s not in CHANGE_TYPES:
                    problems.append(
                        f"'## {name}': '### {s}' is not one of "
                        f"{'/'.join(CHANGE_TYPES)}"
                    )
            known = [s for s in subs if s in CHANGE_TYPES]
            if len(set(known)) != len(known):
                problems.append(f"'## {name}': duplicate change-type heading")
            order = [CHANGE_TYPES.index(s) for s in known]
            if order != sorted(order):
                problems.append(
                    f"'## {name}': change types must appear in "
                    f"{'/'.join(CHANGE_TYPES)} order"
                )
            if not subs:
                problems.append(
                    f"'## {name}': needs at least one "
                    f"'### Added/Changed/Fixed/Removed' group"
                )
            if not any(l.startswith("- ") for l in body):
                problems.append(f"'## {name}': no bullets")

        # bullets
        for i, l in enumerate(lines):
            if not l.startswith("- "):
                continue
            content = l[2:]
            if content.startswith("**") and not content.startswith("**Breaking:**"):
                problems.append(
                    f"line {i+1}: bold bullet lead-in — bold is only for a "
                    f"'**Breaking:**' marker"
                )
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if nxt.startswith("  ") and nxt.strip():
                problems.append(
                    f"line {i+2}: wrapped bullet — one change per bullet, one line per bullet"
                )

    status = "FAIL" if problems else "ok"
    print(f"{status}  {path}")
    for problem in problems:
        print(f"      - {problem}")
    total_failures += 1 if problems else 0

if total_failures:
    print()
    print(f"{total_failures} of {len(paths)} release-note file(s) do not meet the standard.")
    sys.exit(1)

print(f"All {len(paths)} release-note file(s) meet the standard.")
PY
