# Firmware evidence

The implementation is scoped to HP board 8DA8. BIOS F.11 was tested on the laptop. The driver checks the expected ACPI method signatures and readbacks at load time. Other BIOS versions default to read-only access. Administrators can explicitly enable writes for testing on the same board. It was derived by examining the DSDT and SSDTs from that board with [ACPICA iASL](https://github.com/acpica/acpica). The AML dump is machine-specific. This repository contains source and notes.

HP's packaged F.11 and F.13 images for board 8DA8 contain byte-for-byte identical DSDT, HP WMI, and UCSI ACPI tables. Those tables cover the fan mailbox and the battery pause and resume methods. F.13 still needs a live fan and charging test because the embedded controller's behavior can differ. [F.11 package metadata](https://ftp.hp.com/pub/softpaq/sp165501-166000/sp165708.cva) · [F.13 package metadata](https://ftp.hp.com/pub/softpaq/sp172501-173000/sp172874.cva)

## Fan control

| Firmware path | Observation on 8DA8 F.11 |
| --- | --- |
| Fan `_FST` | Reads the embedded controller tachometer in increments of 50 RPM. |
| Fan `_FSL` | Stores the ACPI fan-level value in a firmware variable. The method body contains no hardware fan-target write. |
| Fan `_DSM` | Implements the Microsoft fan operating ranges and RPM notifications. Notification trip points are separate from the requested fan speed. |
| HP gaming WMI max-fan handler | Returns success without programming a fan speed on this board. |
| HP thermal profile methods | Change the firmware thermal mode. Testing confirmed profile readback but did not establish an RPM difference from changing the mode. |
| HP OEM fan target path | Sets the EC fan override before writing the target. Clearing the override returns ownership to HP automatic control. Confirmed with RPM telemetry on physical hardware. |

References for interpretation are the [ACPI fan specification](https://uefi.org/specs/ACPI/6.6/11_Thermal_Management.html), the [Linux ACPI fan documentation](https://docs.kernel.org/admin-guide/acpi/fan_performance_states.html), and [Microsoft's fan operating range and trip point specification](https://learn.microsoft.com/windows-hardware/design/device-experiences/design-guide#fan-trip-points).

## Thermal profile readback

The profile occupies the low byte of the HP WMI reply on the board we examined. Other bytes hold status. An unpatched driver can treat the full reply as the mode and return `EINVAL`. Related patches demonstrate the same pattern on [OmniBook X Flip 14-fm0xxx](https://lists.openwall.net/linux-kernel/2026/10/21/2744) and [OmniBook Ultra 14-kd0xxx](https://lkml.iu.edu/2611.1/13611.html).

## Operating limits

The controller leaves the fan in firmware control below the first temperature point or when its requested speed is no higher than the firmware's initial fan target. An automatic check periodically gives the firmware time to reevaluate its target. The driver limits requests to 4,500 RPM and keeps the override for at most 30 seconds. HP then controls the fan for at least eight seconds before the driver resamples its target. The driver also releases the override if userspace stops renewing the six-second lease, if tachometer or target readback fails, or if the ACPI temperature is unavailable or reaches the cutoff. Linux's normal thermal throttling and firmware recovery mechanisms still apply.

Both control modules hold a reference while they own a firmware override and retry restoration until it is verified. Normal module removal is blocked until that reference is released. Allow the watchdog to recover or reboot if firmware stops responding. Forced removal bypasses this protection.
