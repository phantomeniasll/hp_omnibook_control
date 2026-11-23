# HP OmniBook Fan Curves

A desktop editor and background fan controller for the **HP OmniBook X Flip 16-ar0xxx**, board **8DA8**, BIOS **F.11**. It includes four editable curves, timed Fan Boost, and live hardware temperatures.

| Desktop or distribution | Setup |
| --- | --- |
| Linux Mint 22 Cinnamon | [Install the Cinnamon application and background service](docs/mint.md) |
| NixOS | [Use the NixOS module and optional Plasma 6 widget](docs/nixos.md) |

## What works

- **Quiet, Balanced, Cool, and Performance** each have their own editable curve. Automatic is the initial selection.
- The background service applies the curve independently of the desktop editor. The kernel module limits the duration of an override if the service stops responding.
- **Fan Boost** requests up to 4,500 RPM for 30 seconds.
- The editor shows live CPU, GPU, SSD, system, and Wi-Fi temperatures where the kernel exposes them.
- The separate HP firmware buttons use the kernel's readable HP profile interface when available.
- The optional Linux charge limiter pauses at 80% and resumes at 75% while the service is running.
- The [power management notes](docs/power-management.md) cover charge thresholds and the read-only battery research tool.
- The [HP companion notes](docs/hp-companion.md) map the Windows app's other features to Linux interfaces and include a Windows capture tool.

On the original hardware under NixOS, a custom curve raised the observed fan speed from 3,150 to 3,550 RPM. Returning to Automatic restored 3,150 RPM. Fan Boost reached 4,450 RPM against a 4,500 RPM request and returned to firmware control after its timeout. The Mint instructions are an adaptation. Hardware testing on Mint is still needed.

Check the target system before installing anything:

```sh
cat /sys/class/dmi/id/board_name /sys/class/dmi/id/bios_version
```

The expected lines are `8DA8` and `F.11`. The kernel module also checks the HP vendor identifier. Do not extend the match to another board or BIOS without verifying its firmware interface.

## Repository layout

- [app/](app/) contains the shared curve editor, controller, presets, and sensor reader.
- [driver/](driver/) contains the board-specific Linux kernel module.
- [packaging/mint/](packaging/mint/) contains the Cinnamon launcher and Mint service installer.
- [packaging/nixos/](packaging/nixos/) contains the Nix packages, NixOS module, and standalone Plasma widget.
- [tools/battery-query/](tools/battery-query/) contains the read-only battery policy probe.
- [docs/firmware.md](docs/firmware.md) records the firmware evidence and supporting sources.

The source is available under [GPL-2.0-only](LICENSES/GPL-2.0-only.txt).
