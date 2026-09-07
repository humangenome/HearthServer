-- FName::FName(const TCHAR*, EFindName)  Bellwright UE5.7.4 build 23760023
-- PDB ??0FName@@QEAA@PEB_WW4EFindName@@@Z .text RVA 0x13bb3d0; exact AOB unique in .text.
function Register()
    return "48 89 5C 24 08 57 48 83 EC 30 48 8B D9 48 89 54 24 20"
end
function OnMatchFound(MatchAddress)
    return MatchAddress
end
