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
    # The device unit is the boot event: this service is pulled in only when
    # watchdog0 exists, and the read happens after that event.
    wantedBy = [ "dev-watchdog0.device" ];
    after = [ "dev-watchdog0.device" ];
    bindsTo = [ "dev-watchdog0.device" ];
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
