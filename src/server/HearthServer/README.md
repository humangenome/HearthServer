# HearthServer

The per-instance sidecar — `HearthServer.exe`. Runs Source RCON, Source A2S
query, and the loopback HTTP admin API for one Bellwright host. It does NOT own
the game-process lifecycle and there is NO display head / menu-drive: the SS panel
PowerShell (`bellwrightLauncherHostCommand`) launches the per-customer exe directly
(CREATE_SUSPENDED), pins CPU affinity before resume, and stops it; `GameInstallRoot`
stays empty (same as SN2/Beacon). The game hosts headless via `-nullrhi` + the
Engine.ini `LocalMapOptions=?listen` config — no GPU, no WARP, no virtual display.

Same lifecycle model as Subnautica 2: the SS panel PowerShell
(`bellwrightLauncherHostCommand`) owns the game-process lifecycle and
HearthServer's internal supervisor stays idle on an EMPTY `GameInstallRoot`. The
panel launches the per-customer exe directly (CREATE_SUSPENDED with the `-nullrhi`
no-GPU args), pins CPU affinity before resume, reaps `CrashReportClient`/`WerFault`,
and restarts. HearthServer only serves RCON / Source A2S query / the loopback HTTP
admin API for that instance — it does NOT launch, pin, or relaunch the game.

PORT FROM BEACON: copy `BeaconServer` (Program + Configuration + Services +
Static), rename the namespace and the `Beacon` config section to `Hearth`, and
swap the SN2 launch/lifecycle for the Bellwright recipe in `docs/RUNTIME.md` and
`scripts/host-instance.ps1`.

The `Mods` settings nest UNDER the `Hearth` config section, not at the top
level (same binding quirk Beacon has).
