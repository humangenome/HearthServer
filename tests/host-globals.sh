#!/usr/bin/env bash
# Run from the repository root: bash tests/host-globals.sh [path/to/main.lua]
# Fails when the host mod reads a lowercase global that is not on the list below.
# In this file every helper is a local, so a lowercase global read almost always
# means a helper used above the line that defines it: Lua resolves the name as a
# global, gets nil, and the call raises inside a pcall on every pass. v0.18.58's
# first lab run stopped the join service that way, and a fog sweep had never run
# for the same reason. A new intentional global goes on the list with a reason.
set -euo pipefail
main="${1:-dist/ue4ss-server/Mods/bw_host/Scripts/main.lua}"
allowed=(
  # Lua standard library
  assert collectgarbage coroutine debug error getmetatable io ipairs load math next
  os package pairs pcall print rawequal rawget rawlen rawset require select
  setmetatable string table tonumber tostring type unpack utf8 xpcall
  # intentional globals of the mod (shared with UE4SS callbacks)
  ensureRestartHook fastPinTick hostUp
)
found="$(luac5.4 -l -l -p "$main" 2>/dev/null | grep -oE '(GETTABUP|GETTABLE).*_ENV "[a-z][A-Za-z0-9_]*"' | sed -E 's/.*_ENV "([^"]+)"/\1/' | sort -u)"
bad=()
for name in $found; do
  ok=0
  for a in "${allowed[@]}"; do [[ "$name" == "$a" ]] && ok=1 && break; done
  [[ $ok -eq 0 ]] && bad+=("$name")
done
if [[ ${#bad[@]} -gt 0 ]]; then
  echo "host mod reads undeclared lowercase globals (a local used above its definition?): ${bad[*]}" >&2
  exit 1
fi
echo "ok - no undeclared lowercase globals in $main"
