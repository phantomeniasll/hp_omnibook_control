{
  description = "Fan curves and temperature monitoring for HP OmniBook board 8DA8";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }: {
    nixosModules.default = import ./packaging/nixos/module.nix;
    packages.x86_64-linux =
      let
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        driver = pkgs.linuxPackages_latest.callPackage ./packaging/nixos/driver.nix { };
      in {
        inherit driver;
        default = pkgs.callPackage ./packaging/nixos/package.nix {
          inherit driver;
          plasmaWidget = true;
        };
      };
  };
}
