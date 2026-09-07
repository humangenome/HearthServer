# dist/engine-ini — Bellwright Engine.ini reference templates

Reference shape only. The **authoritative** transport swap for Bellwright is the
runtime UE4SS Lua (`bw_host` host-side, `HearthConnect` client-side): the spike
proved Engine.ini NetDriver config is **ignored** on this build (UE5.7.4 "Mist"),
so the mods rewrite `NetDriverDefinitions[GameNetDriver]` → stock `IpNetDriver`
live. These files document the intended config shape and the no-Steam stance.

The real, per-instance host `Engine.ini` is emitted by `host-instance.ps1` on
every launch, with the instance's real gameplay port baked in. `<GAMEPLAY_PORT>`
here is a placeholder, never a default.

No-Steam stance: Bellwright hosts with Steam closed (OSS falls to Null on its
own); the templates disable the Steam OSS so nothing hydrates a platform session.
The OSS/auth/save-key values were confirmed by the real-map host + retail-join gate.
