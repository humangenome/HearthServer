# Vendored UE4SS cores (pinned)

`UE4SS.dll` is vendored here and SHA-verified at release time instead of being
downloaded from UE4SS-RE's floating `experimental-latest` tag. That tag
overwrites its assets in place whenever UE4SS-RE re-cuts a build, so a release
silently picks up whatever nightly happens to be live that day. In v0.1.43 that
drift shipped a client core that failed to load on fresh Windows machines with
Bad Image `0xc0e90002`, dropping players at the main menu.

The core version is decoupled from the live Steam build: the engine hooks are
driven by the shipped `UE4SS_Signatures/` override packs, not a core's built-in
scanner. So a pinned, older-but-known-good core works fine against a newer game
build as long as the signature pack targets that build.

Cores are pinned independently:

| Path | sha256 (prefix) | Origin | Rationale |
|------|-----------------|--------|-----------|
| `client/UE4SS.dll` | `c8627a…` | shipped in launcher v0.1.37 | proven to load + run the client mods on players' fresh PCs |
| `server/UE4SS.dll` | `2ad348…` | official `UE4SS_v3.0.1-1011-gb50986bd.zip` | includes safe invalid-field userdata and `IsValidField`; required by `bw_host` optional UObject probes |

Full pins live in `.github/workflows/release.yml` (`UE4SS_CLIENT_SHA256` /
`UE4SS_SERVER_SHA256`). The release build fails hard if a vendored DLL's hash
doesn't match its pin.

## Moving a pin

1. Drop the new `UE4SS.dll` at the matching path.
2. Update the corresponding `*_SHA256` in `release.yml`.
3. Validate the matching lifecycle before tagging: clean-machine Connect for a
   client move; start, join, disconnect, reconnect, and forced-GC coverage for
   a server move.

The pinned server core was taken from the immutable official archive
`UE4SS_v3.0.1-1011-gb50986bd.zip` (archive sha256
`aa181789dc7226bcec94f13f054ff10477d7383321ffb98dbc3666a159b182a8`).
