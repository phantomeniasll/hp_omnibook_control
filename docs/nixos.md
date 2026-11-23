# NixOS setup

Add the project as a flake input in your system configuration. This local-path example also works before the project has a remote.

```nix
inputs.omnibook-fan-curves.url = "path:/absolute/path/to/omnibook-fan-curves";
```

Add the module to your host's module list:

```nix
inputs.omnibook-fan-curves.nixosModules.default
{
  services.omnibookFanCurves.enable = true;
  services.omnibookFanCurves.plasmaWidget = true;
  services.omnibookFanCurves.batteryLimit.enable = true;
  services.omnibookFanCurves.controlUsers = [ "your-username" ];
}
```

Set `plasmaWidget = false` on other desktops. Rebuild using your normal NixOS flake workflow. The module builds against the host's selected kernel and adds **HP Fan Curves** to the application menu. On Plasma 6, add **HP Thermal Mode** through **Add Widgets** to get quick profile actions, sensor readings, and access to the editor.

List the local accounts that may change controls in `controlUsers` and sign out and back in after activation. Members can run the fan and battery controls without password prompts.

With `services.omnibookFanCurves.batteryLimit.enable = true` (which loads the charge-control module needed for both the **HP hard 80% limit** and the **Custom soft limit**), use **Battery Charging** in the Plasma widget or **Battery charging** in the editor or run `hp-charge-limit enable` / `hp-charge-limit native-enable`. Set the stop and resume percentages in the widget or editor. The CLI uses hysteresis in percentage points, for example `hp-charge-limit set 80 5`. The custom soft limit is off on a fresh installation. Firmware compatibility on board 8DA8 is checked automatically. See [power management](power-management.md) for runtime and suspend behavior.

This package's Plasma integration is a standalone widget. It is compatible with the stock Power & Battery widget and does not require modifying Plasma Shell or PowerDevil. The software exposes HP's separate modes if the running `hp-wmi` driver offers readable profiles. The [firmware notes](firmware.md) explain the readback issue on some kernels.

The service starts with **Automatic** on a fresh installation. Use the editor to apply a custom curve, select Automatic to hand control back to HP, or stop the service with:

```sh
sudo systemctl stop omnibook-fan-curves.service
```

Saved curves live in `/var/lib/omnibook-fan-curves/curves.json`. On a host previously set up with the experimental installer, remove the old unmanaged unit before installing the declarative one. Inspect `systemctl show -p FragmentPath omnibook-fan-curves.service` to identify it. If you used the unmanaged battery installer too, check `omnibook-charge-limit.service`, `omnibook-control.socket`, and `omnibook-control.service` (or the old `omnibook-control@.service` template) under `/usr/local/lib/systemd/system` before switching to declarative units.

## Package checks

```sh
nix flake check --no-build
nix build .#driver
nix build
```

The flake's standalone build uses its pinned latest kernel. The NixOS module instead uses your host's `boot.kernelPackages`.

## Existing unmanaged installation

For a live upgrade on a host that already runs the unmanaged service, build the Nix package and invoke its immutable installer. Pass the paths and verified SHA-256 hashes of modules built for the currently running kernel. The fan module and its hash are optional if only updating the charge limiter.

```sh
sudo ./result/bin/hp-install-live /path/to/omnibook-charge-control.ko CHARGE_SHA256 \
  /path/to/omnibook-fan-probe.ko FAN_SHA256
```
