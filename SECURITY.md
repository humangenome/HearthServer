# Security Policy

## Reporting a vulnerability

If you've found a security issue in HearthServer (the supervisor, RCON, Source query, the admin API, persistence, or the save guard), please **do not** open a public GitHub issue.

Report it privately through GitHub: **[open a security advisory](https://github.com/HumanGenome/HearthServer/security/advisories/new)** (Security > Advisories > "Report a vulnerability"). The report is visible only to you and the maintainers until a fix ships.

That is the only reporting channel. There is no security mailing address; anything sent to one will not reach us.

Include:
- A description of the vulnerability
- Steps to reproduce
- Affected component (supervisor / RCON / query / admin API / persistence / save guard)
- HearthServer version, from `GET /api/v1/info`
- Whether the issue is currently being exploited

We aim to acknowledge reports within 72 hours and provide a triage update within 7 days.

## Scope

In scope:
- Remote code execution or unauthenticated takeover of `HearthServer.exe`
- Authentication bypass on the admin HTTP API (HMAC signing, replay window) or on RCON
- Source query handling that lets an unauthenticated packet crash or hang the supervisor
- IPC injection through the named pipe or the host mod's file IPC
- Save file corruption that lets a connected client write arbitrary host files
- Anything that defeats the save protection baseline or the offline-player ledger

Out of scope:
- Hardware-host vulnerabilities (those belong to your hosting provider)
- Vulnerabilities in retail Bellwright itself (report to the game's publisher)
- Vulnerabilities in third-party mods running on a Hearth server
- Anti-cheat / cheating concerns — Hearth does not provide anti-cheat

Launcher and client issues belong on the [Hearth hub](https://github.com/HumanGenome/Hearth/security/advisories/new); either advisory form reaches the same maintainers.
