-- FUObjectHashTables::Get()  Bellwright UE5.7.4  build 24840601  PDB ?Get@FUObjectHashTables@@SAAEAV1@XZ .text RVA 0x15f2c60
-- magic-static entry; guard-var rip disps are per-build unique. Re-derived after Steam update 24204729 -> 24840601 (2026-09-01); before that 24020048 -> 24204729
-- (the prior build's fixed disps stopped matching, which hung UE4SS init in an endless Phase-2 AOB loop).
function Register()
    return "40 53 48 83 EC 20 8B 0D C4 C1 C5 0A 65 48 8B 04 25 58 00 00 00 BA 84 1A 00 00 48 8B 04 C8 8B 04 02 39 05 81 C8 98 0A"
end
function OnMatchFound(MatchAddress)
    return MatchAddress
end
