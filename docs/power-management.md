# Power management

OS power profiles, HP thermal modes, battery charge ceilings, and the custom fan curve are separate controls. The fan service reads temperatures and manages a fan override. It does not alter CPU policy or battery charging.

## Battery Care and an 80% ceiling

HP documents an 80% **Battery Care Function** setting in firmware on supported consumer models. On a Linux system with a working native battery threshold, look for `charge_control_end_threshold` under the battery in `/sys/class/power_supply/`. A TLP configuration entry alone cannot create a missing kernel interface.

On the original 8DA8/F.11 system, `BAT0` exposed charging state and charge percentage but did not expose a kernel charge-threshold attribute. The firmware dump shows HP WMI battery control via `GBCC/SBCC`, charging modes via `GBCO/SBCO`, and a separate `GTCS/STCS` pair that reads and writes two charging-related bytes. Their meaning as percentage thresholds is unverified on this board.

The first live capture returned `GTCS: 04 00 00 00` and `GBCO: 00 ff 00 00`. Both values are raw firmware replies. This sample provides no readback that can verify an 80% ceiling.

## Linux software limit

On 8DA8/F.11, a controlled test at 75% changed the battery from Charging at about 10.3 W to Not charging at 0 W with AC connected. Firmware reported inhibit mode `04`. The related upstream driver uses the automatic mode argument `00`, but on this board it reported Automatic while the battery still showed 0 W. This board's restore branch `04` also clears the pause flag. After that branch ran, the measured battery charge rate returned to about 8.3 W.

The optional Linux service uses these two verified actions. While Linux is running on AC, it pauses at 80%, resumes at 75%, and preserves the current state between those levels. It returns control to HP when unplugged, stopped, or preparing for suspend. The driver also expires an unrenewed pause after 60 seconds. Linux must be awake and running to enforce the ceiling. The firmware can charge beyond 80% while the laptop is asleep or powered off.

```sh
sudo hp-charge-limit enable
hp-charge-limit status
sudo hp-charge-limit disable
```

The same toggle appears in the desktop editor while the service is running. See the [NixOS setup](nixos.md) and [Mint setup](mint.md) for service activation.

## Read-only research

In its default mode, the [probe](../tools/battery-query/) reports `GTCS` and `GBCO` without changing charging settings. Record its output with a known setting selected in the HP Windows app, then change only that setting and collect a second sample. Check the actual stop percentage separately before offering a write control.

- [HP Battery Care and UEFI diagnostics](https://support.hp.com/us-en/document/ish_2854458-2733239-16)
- [Linux power supply class](https://docs.kernel.org/power/power_supply_class.html)
- [Linux HP WMI charge-behaviour implementation discussion](https://lists.openwall.net/linux-kernel/2026/05/31/584)
- [Microsoft WMI trace documentation for the HP app](https://learn.microsoft.com/windows/win32/wmisdk/tracing-wmi-activity)

## Run the read-only probe

From the top of the repository, on the supported board and firmware:

```sh
make -C "/lib/modules/$(uname -r)/build" M="$PWD/tools/battery-query" modules
sudo sh tools/battery-query/read.sh
```

On NixOS, use the running kernel's development output in place of `/lib/modules/$(uname -r)/build`. This optional diagnostic is independent of the fan service.
