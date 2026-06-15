# Hearth.Abstractions

Shared service interfaces (`IHearthService` and friends) implemented by
HearthServer and consumed by the tools/launcher.

PORT FROM BEACON: copy `Beacon.Abstractions` (the `IBeaconService` interfaces)
and rename to `Hearth.Abstractions`. These are interface-only and port
verbatim.
