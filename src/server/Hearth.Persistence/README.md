# Hearth.Persistence

SQLite-backed persistence (HearthDb): bans, scheduler, audit, character store,
save-snapshot bookkeeping.

PORT FROM BEACON: copy `Beacon.Persistence` (SQLite/Dapper, the BeaconDb schema)
and rename. Schema ports verbatim; add Bellwright-specific tables only as the
feature set diverges.
