DefinitionBlock ("", "SSDT", 2, "OMBK", "BIOSREAD", 1)
{
    External (\MSMT, MutexObj)
    External (\_SB.WMID.EHWB, FieldUnitObj)
    External (\_SB.WMID.HWRC, FieldUnitObj)
    External (\_SB.WMID.GHMI, MethodObj)

    Method (\_SB.WMID.OBBQ, 1, Serialized)
    {
        If (Acquire (\MSMT, 0x03E8))
        {
            Return (0x02)
        }

        \_SB.WMID.EHWB = Arg0
        \_SB.WMID.HWRC = 0x02
        \_SB.WMID.GHMI (Zero, 0xFE)
        Local0 = \_SB.WMID.HWRC
        Local1 = \_SB.WMID.EHWB
        Release (\MSMT)

        If (Local0 != Zero)
        {
            Return (0x03)
        }

        If (SizeOf (Local1) < 0x0400)
        {
            Return (0x04)
        }

        // The firmware enumeration reply starts with a length-prefixed name.
        CreateWordField (Local1, Zero, NLEN)
        If (NLEN != 0x16)
        {
            Return (Zero)
        }
        If (ToString (Mid (Local1, 0x02, NLEN), NLEN) != "Battery Health Manager")
        {
            Return (Zero)
        }

        // Skip the name, flags, and the separate value preceding CurrentValue.
        Local2 = NLEN + 0x06
        CreateWordField (Local1, Local2, VLEN)
        Local2 += VLEN + 0x02
        If (Local2 > 0x03FE)
        {
            Return (0x04)
        }
        CreateWordField (Local1, Local2, CLEN)
        Local2 += 0x02
        If ((CLEN == Zero) || ((Local2 + CLEN) > 0x0400))
        {
            Return (0x04)
        }

        Local3 = ToString (Mid (Local1, Local2, CLEN), CLEN)
        If (Local3 == "Maximize my battery health On")
        {
            Return ("Maximize my battery health On")
        }
        If (Local3 == "Maximize my battery health Off")
        {
            Return ("Maximize my battery health Off")
        }
        Return (0x04)
    }
}
