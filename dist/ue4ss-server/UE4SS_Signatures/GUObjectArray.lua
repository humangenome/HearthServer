-- GUObjectArray (FUObjectArray)  Bellwright UE5.7.4 build 23760023
-- PDB ?GUObjectArray@@3VFUObjectArray@@A .data RVA 0xbf4ab20; AOB unique at .text RVA 0xeb6797.
-- AOB spans prev-fn tail + this fn entry; the GUObjectArray lea (48 8D 0D) is at match+13.
function Register()
    return "48 83 C4 38 E9 ?? ?? ?? ?? 48 83 EC 28 48 8D 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ??"
end
function OnMatchFound(MatchAddress)
    local leaInstr = MatchAddress + 13
    local nextInstr = leaInstr + 7
    local offset = DerefToInt32(leaInstr + 3)
    return nextInstr + offset
end
