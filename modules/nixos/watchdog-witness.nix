{ lib, horizon, pkgs, ... }:
let
  enabled = horizon.node.behavesAs.router or false;
in
{
  systemd.services.criomos-watchdog-witness = lib.mkIf enabled {
    description = "Record the SP5100 watchdog boot witness";
    # The device unit is the event.  Its static wants link covers ordinary boot
    # and a driver which appears late; switch-to-configuration also starts a
    # newly installed dependency of an already-active device unit.
    wantedBy = [ "dev-watchdog0.device" ];
    after = [ "dev-watchdog0.device" ];
    bindsTo = [ "dev-watchdog0.device" ];
    # Keep the successful observation active for the life of this boot.  A
    # later configuration switch must neither stop nor repeat the sysfs read.
    restartIfChanged = false;
    stopIfChanged = false;
    path = [ pkgs.coreutils pkgs.systemd ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash ${./watchdog-witness.sh}";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
    };
  };
}
