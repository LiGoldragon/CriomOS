{ config, lib, horizon, pkgs, ... }:
let
  nodeServices = import ./node-services.nix { inherit lib; };
  capabilities = horizon.node.capabilities or [ ];
  witness = nodeServices.payload capabilities "watchdogWitness";
  enabled = nodeServices.has capabilities "watchdogWitness";
  routerScoped = (witness.scope or null) == "router";
in
{
  assertions = lib.optional enabled {
    assertion = routerScoped && (horizon.node.behavesAs.router or false);
    message = "watchdogWitness is a router-scoped capability and requires behavesAs.router";
  };

  systemd.services.criomos-watchdog-witness = lib.mkIf (enabled && routerScoped) {
    description = "Record the SP5100 watchdog boot witness";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" "dev-watchdog0.device" ];
    unitConfig = {
      ConditionPathExists = "/sys/class/watchdog/watchdog0/identity";
      ConditionPathExists = "/sys/class/watchdog/watchdog0/bootstatus";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${./watchdog-witness.sh}";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
    };
  };
}
