-- StaticConstructObject_Internal  Bellwright UE5.7.4 build 23760023
-- PDB ?StaticConstructObject_Internal@@... .text RVA 0x15e7d60; exact AOB unique in .text.
function Register()
    return "4C 8B DC 55 53 41 56 49 8D AB 38 FE FF FF"
end
function OnMatchFound(MatchAddress)
    return MatchAddress
end
