# Firmware evidence

The implementation is scoped to HP board 8DA8. BIOS F.11 was tested on the laptop. The drivers check for the expected ACPI methods and plausible readbacks at load time. When a fan target or charge pause is requested, the driver checks that firmware confirms it. A rejected command triggers restoration and blocks new writes from that driver until it is reloaded. It was derived by examining the DSDT and SSDTs from that board with [ACPICA iASL](https://github.com/acpica/acpica). The AML dump is machine-specific. This repository contains source and notes.

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

## Native 80% battery limit

On Windows, a myHP toggle from enabled to disabled changed the BIOS enumeration named `Battery Health Manager` from `Maximize my battery health On` to `Maximize my battery health Off`. The other battery-related settings in the before-and-after snapshots stayed the same.

On the tested Linux system, the WMI BIOS enumeration GUID `2D114B49-2DFB-4130-B8FE-4A3C09E75133` advertises 89 instances under object ID `BC`. The kernel log shows that `WQBC` aborts with `AE_AML_OPERAND_VALUE` when creating a zero-length field. The firmware method builds fields for each possible value even when the corresponding string length is zero. [Linux enumeration GUID](https://code.googlesource.com/linux/torvalds/linux/+/8bfab832ad6905ba70e69bad87a78f6d90cce64a/drivers/platform/x86/hp/hp-bioscfg/bioscfg.h#68) · [Linux enumeration code](https://code.googlesource.com/linux/torvalds/linux/+/8bfab832ad6905ba70e69bad87a78f6d90cce64a/drivers/platform/x86/hp/hp-bioscfg/bioscfg.c#878)

An offline ACPICA test passed a synthetic enumeration record with two populated options and zero-length padding through the firmware method. The stock method aborted with the same error. A modified method that skips empty fields returned the setting and both values. A separate live Linux diagnostic read the same firmware enumeration record at instance 79 and returned `Maximize my battery health On`. The diagnostic used a temporary ACPI method to read the setting and removed that method afterward. It made no BIOS setting writes. Many shipped SSDTs share the affected table's OEM identity, so that identity alone cannot select a safe whole-table replacement.

Linux's HP driver uses method 1 of the BIOS setter WMI GUID. The firmware implements it as `WMBA`. A live Linux test on 8DA8 wrote Off and verified the new value, then wrote On and verified restoration of the original setting. Firmware returned status zero for both writes. The test verified the setting only. The charging cutoff still needs a charging session with the app's custom pause disabled. [Linux HP BIOS setter](https://codebrowser.dev/linux/linux/drivers/platform/x86/hp/hp-bioscfg/biosattr-interface.c.html#246)

## Operating limits

The controller leaves the fan in firmware control below the first temperature point or when its requested speed is no higher than the firmware's initial fan target. An automatic check periodically gives the firmware time to reevaluate its target. The driver limits requests to 4,500 RPM and gives custom curves up to 120 seconds of continuous override before an eight-second HP control window and a fresh firmware sample. Fan Boost runs for up to 30 seconds and then resumes the selected fan mode. The eight-second firmware sample applies only when the continuous ownership interval expires. The driver also releases the override if userspace stops renewing the six-second lease, if tachometer or target readback fails, or if the ACPI temperature is unavailable or reaches the cutoff. Linux's normal thermal throttling and firmware recovery mechanisms still apply.

Both control modules hold a reference while they own a firmware override and retry restoration until it is verified. Normal module removal is blocked until that reference is released. Allow the watchdog to recover or reboot if firmware stops responding. Forced removal bypasses this protection.

The fan driver reports `recovering` until it verifies that the firmware cleared its override. The application shows that state even if a requested handoff failed or the watchdog is now performing the retry.
