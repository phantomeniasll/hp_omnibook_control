# HP OmniBook Fan Curves for Linux Mint Cinnamon

A Cinnamon menu app and systemd background service for four editable fan curves. It includes a 30-second Fan Boost and live CPU, GPU, SSD, system, and Wi-Fi temperatures when the kernel exposes those sensors.

## Check the laptop first

The hardware interface was verified on an **HP OmniBook X Flip 16-ar0xxx with board 8DA8 and BIOS F.11**. Other OmniBooks may use different fan firmware. The installer and driver check the board and BIOS before enabling fan control.

Open a terminal in the extracted folder and run:

```sh
sh ./packaging/mint/install.sh --check
```

Installation targets Linux Mint 22 Cinnamon and builds a module for the currently running kernel. Fan control was tested on the original laptop under NixOS with kernel 7.2.10. The Mint installer and app are an adaptation and have not been tested on physical Mint hardware.

## Install on Mint 22 Cinnamon

```sh
sudo apt update
sudo apt install build-essential "linux-headers-$(uname -r)" kmod pkexec python3 python3-pyqt6
sh ./packaging/mint/install.sh
```

The installer builds as your user, then requests administrator access to test the module and install the app and service. Keep the extracted folder for future kernel updates.

Open **HP Fan Curves** from the Cinnamon application menu. Right-click the menu result and choose **Add to panel** if you want quick access. The app can be closed while the service runs.

- Choose **Quiet**, **Balanced**, **Cool**, or **Performance** in the curve editor.
- Edit the CPU temperature and RPM points, then select **Save and Apply**. **Save Curves** stores edits without changing the selected curve.
- Choose **Use Automatic** to return the fan to HP firmware control. Automatic is the initial setting after a fresh install.
- **Fan Boost** requests 4,500 RPM for up to 30 seconds, then returns to the selected curve or Automatic.
- The separate **HP firmware modes** buttons are enabled when the running HP driver exposes a readable profile. Older kernels may leave them disabled. The installer does not patch or replace the stock HP driver.

The fan returns to firmware control below the curve's first temperature, when HP already calls for at least as much cooling, during a safety-temperature cutoff, or if the service stops renewing the override. Curves use target points from 3,000 to 4,500 RPM in 50 RPM steps. Temperatures must increase strictly between 30°C and 82°C.

## Kernel updates and Secure Boot

After booting a new kernel, install its matching headers and run `sh ./packaging/mint/install.sh` again. This keeps your saved curves. Until a module exists for the running kernel, HP automatic fan control remains in charge.

If Secure Boot rejects the module, the installer stops at the load test. With an enrolled Machine Owner Key, build with `sh ./packaging/mint/install.sh --build-only`, sign the reported module using your system's enrolled key, then install it with `sh ./packaging/mint/install.sh --install-built driver/omnibook-fan-probe.ko`. See [Ubuntu's Secure Boot signing documentation](https://documentation.ubuntu.com/security/security-features/platform-protections/secure-boot/).

## Check or remove

```sh
systemctl status omnibook-fan-curves.service
sudo journalctl -b -u omnibook-fan-curves.service
sudo sh ./packaging/mint/uninstall.sh
```

Removal stops the service and unloads the driver. Saved curves remain at `/var/lib/omnibook-fan-curves/curves.json`.

## Battery charging

When the charge module was built alongside the fan module, the installer also starts the charge-limit service. Use **Battery charging** in the editor or run `sudo hp-charge-limit set 80 5` and `sudo hp-charge-limit enable`. On Secure Boot systems the charge module must be signed separately before it can load.

See [power management](power-management.md) for HP Battery Care, Linux charge thresholds, and the separate research probe.
