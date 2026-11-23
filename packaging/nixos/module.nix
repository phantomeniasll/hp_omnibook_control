{ config, lib, pkgs, ... }:

let
  cfg = config.services.omnibookFanCurves;
  driver = config.boot.kernelPackages.callPackage ./driver.nix { };
  package = pkgs.callPackage ./package.nix { inherit driver; inherit (cfg) plasmaWidget; };
  app = "${package}/libexec/omnibook-fan-curves";
in {
  options.services.omnibookFanCurves = {
    enable = lib.mkEnableOption "HP OmniBook 8DA8 fan curves";
    plasmaWidget = lib.mkEnableOption "the optional Plasma 6 fan control widget";
  };

  config = lib.mkIf cfg.enable {
    security.polkit.enable = lib.mkDefault true;
    environment.systemPackages = [ package ] ++ lib.optional cfg.plasmaWidget pkgs.kdePackages.plasma5support;

    systemd.services.omnibook-fan-curves = {
      description = "HP OmniBook custom fan curves";
      after = [ "systemd-modules-load.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionArchitecture = "x86-64";
      serviceConfig = {
        ExecStart = "${app}/curve-python ${app}/curve_control.py run";
        StateDirectory = "omnibook-fan-curves";
        StateDirectoryMode = "0755";
        RuntimeDirectory = "omnibook-fan-curves";
        RuntimeDirectoryMode = "0755";
        Restart = "on-failure";
        RestartSec = 3;
        TimeoutStopSec = 10;
      };
    };
  };
}
