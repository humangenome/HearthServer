#!/usr/bin/env bash
# Assert that the tag being released matches what the binaries will report.
#
# HearthVersionInfo reads Directory.Build.props <Version> and serves it from
# /api/v1/info. When the release-prep bump is skipped, the tag and the binary
# disagree permanently: public v0.1.82 ships a server that calls itself 0.1.81,
# and v0.1.65 ships 0.1.64. Neither can be corrected without re-tagging a
# published release, so this runs before the build.
#
# Usage:
#   scripts/check-version-stamp.sh v0.1.85
#   scripts/check-version-stamp.sh v0.1.85 /path/to/other/checkout

set -euo pipefail

TAG="${1:-}"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag e.g. v0.1.85> [repo root]" >&2
  exit 2
fi

VERSION="${TAG#v}"
PROPS="$ROOT/Directory.Build.props"
FAIL=0

fail() { echo "  FAIL: $*"; FAIL=1; }

if [[ ! -f "$PROPS" ]]; then
  echo "FAIL: $PROPS not found" >&2
  exit 1
fi

read_prop() {
  sed -n "s/.*<$1>\(.*\)<\/$1>.*/\1/p" "$PROPS" | head -1
}

ACTUAL_VERSION="$(read_prop Version)"
ACTUAL_ASSEMBLY="$(read_prop AssemblyVersion)"
ACTUAL_FILE="$(read_prop FileVersion)"

echo "==> tag $TAG vs $PROPS"
echo "    Version=$ACTUAL_VERSION AssemblyVersion=$ACTUAL_ASSEMBLY FileVersion=$ACTUAL_FILE"

[[ "$ACTUAL_VERSION" == "$VERSION" ]] || \
  fail "<Version> is $ACTUAL_VERSION, tag says $VERSION — /api/v1/info would report the wrong version"
[[ "$ACTUAL_ASSEMBLY" == "$VERSION.0" ]] || \
  fail "<AssemblyVersion> is $ACTUAL_ASSEMBLY, expected $VERSION.0"
[[ "$ACTUAL_FILE" == "$VERSION.0" ]] || \
  fail "<FileVersion> is $ACTUAL_FILE, expected $VERSION.0"

# The release body comes from this file on the client repo; on the public server
# repo the body comes from the CHANGELOG section instead.
NOTES="$ROOT/.github/release-notes/$TAG.md"
CHANGELOG="$ROOT/CHANGELOG.md"
if [[ -d "$ROOT/.github/release-notes" ]]; then
  if [[ ! -s "$NOTES" ]]; then
    fail "missing or empty release notes at .github/release-notes/$TAG.md"
  fi
elif [[ -f "$CHANGELOG" ]]; then
  if ! grep -q "^## \[$VERSION\]" "$CHANGELOG"; then
    fail "CHANGELOG.md has no '## [$VERSION]' section — the release body would fall back to a placeholder"
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  echo
  echo "Version stamp check failed for $TAG. Bump Directory.Build.props (and the"
  echo "matching release-notes / CHANGELOG section) before tagging."
  exit 1
fi

echo "==> Version stamp matches the tag."
