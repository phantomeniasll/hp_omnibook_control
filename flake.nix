{
  description = "Fan curves and temperature monitoring for HP OmniBook board 8DA8";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      driver = pkgs.linuxPackages_latest.callPackage ./packaging/nixos/driver.nix { };
    in {
      nixosModules.default = import ./packaging/nixos/module.nix;
      packages.x86_64-linux = {
        inherit driver;
        default = pkgs.callPackage ./packaging/nixos/package.nix {
          inherit driver;
          plasmaWidget = true;
        };
      };
      checks.x86_64-linux.unit-tests =
        let
          testSrc = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./app
              ./tests
              ./packaging/mint/cinnamon-applet
            ];
          };
        in pkgs.runCommand "omnibook-fan-curves-tests" {
          nativeBuildInputs = [ pkgs.python3 ];
        } ''
          python3 -m unittest discover -s ${testSrc}/tests -v
          touch "$out"
        '';
    };
}
