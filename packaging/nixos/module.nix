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
    batteryLimit.enable = lib.mkEnableOption "the optional battery charge-limit service";
    controlUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Local users allowed to change fan and battery settings without a prompt.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.omnibook-control.members = cfg.controlUsers;
    environment.systemPackages = [ package ] ++ lib.optional cfg.plasmaWidget pkgs.kdePackages.plasma5support;

    systemd.sockets.omnibook-control = {
      description = "HP OmniBook control socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/omnibook-control.sock";
        SocketMode = "0660";
        SocketGroup = "omnibook-control";
        Accept = true;
        MaxConnections = 16;
        RemoveOnStop = true;
      };
    };

    systemd.services."omnibook-control@" = {
      description = "HP OmniBook privileged control request";
      serviceConfig = {
        ExecStart = "${app}/curve-python ${app}/control_runner.py serve";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        RuntimeMaxSec = 10;
        NoNewPrivileges = true;
      };
    };

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

    systemd.services.omnibook-charge-limit = lib.mkIf cfg.batteryLimit.enable {
      description = "HP OmniBook battery charge limit";
      after = [ "systemd-modules-load.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/sys/class/power_supply/BAT0";
      serviceConfig = {
        ExecStart = "${app}/curve-python ${app}/battery_limit.py run";
        StateDirectory = "omnibook-charge-limit";
        RuntimeDirectory = "omnibook-charge-limit";
        StateDirectoryMode = "0755";
        RuntimeDirectoryMode = "0755";
        Restart = "on-failure";
        RestartSec = 3;
        TimeoutStopSec = 30;
      };
    };
  };
}
