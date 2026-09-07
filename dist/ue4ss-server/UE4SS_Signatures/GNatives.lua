-- GNatives  Bellwright UE5.7.4 build 23760023
-- PDB ?GNatives@@... .data RVA 0xbc00ed0; AOB unique at .text RVA 0x15ae3fa and returns GNatives.
-- AOB: mov rbx,rcx ; lea rdi,[rip+GNatives] ; nop. lea at match+3 (opcode 48 8D 3D + disp4).
function Register()
    return "48 8B D9 48 8D 3D ?? ?? ?? ?? 0F 1F 40 00"
end
function OnMatchFound(MatchAddress)
    local leaInstr = MatchAddress + 3
    local nextInstr = leaInstr + 7
    local offset = DerefToInt32(leaInstr + 3)
    return nextInstr + offset
end
