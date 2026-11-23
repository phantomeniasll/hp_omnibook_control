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
}
```

Set `plasmaWidget = false` on other desktops. Rebuild using your normal NixOS flake workflow. The module builds against the host's selected kernel and adds **HP Fan Curves** to the application menu. On Plasma 6, add **HP Thermal Mode** through **Add Widgets** to get quick profile actions, sensor readings, and access to the editor.

This package's Plasma integration is a standalone widget. It is compatible with the stock Power & Battery widget and does not require modifying Plasma Shell or PowerDevil. The software exposes HP's separate modes if the running `hp-wmi` driver offers readable profiles. The [firmware notes](firmware.md) explain the readback issue on some kernels.

The service starts with **Automatic** on a fresh installation. Use the editor to apply a custom curve, select Automatic to hand control back to HP, or stop the service with:

```sh
sudo systemctl stop omnibook-fan-curves.service
```

Saved curves live in `/var/lib/omnibook-fan-curves/curves.json`. On a host previously set up with the experimental installer, remove the old unmanaged unit before installing the declarative one. Inspect `systemctl show -p FragmentPath omnibook-fan-curves.service` to identify it.

## Package checks

```sh
nix flake check --no-build
nix build .#driver
nix build
```

The flake's standalone build uses its pinned latest kernel. The NixOS module instead uses your host's `boot.kernelPackages`.
