# Read-only runtime evidence for the non-Router UsbDownlink bridge.  Networkd,
# Kea, resolved, NAT and the firewall remain owned by usb-downlink.nix.
{ config, lib, pkgs, horizon, ... }:
let
  capabilities = horizon.node.capabilities or [ ];
  declared = builtins.any (capability: builtins.isAttrs capability && (capability.kind or null) == "usbDownlink") capabilities;
  isRouter = horizon.node.behavesAs.router or false;
  observer = pkgs.callPackage ../../../packages/usb-downlink-observer { };
in {
  config = lib.mkIf (declared && !isRouter) {
    systemd.tmpfiles.rules = [ "d /run/usb-downlink-observer 0755 root root -" ];
    systemd.services.usb-downlink-observer = {
      description = "Passive USB downlink evidence observer";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-networkd.service" "kea-dhcp4-server.service" ];
      wants = [ "systemd-networkd.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${observer}/bin/usb-downlink-observer br-downlink";
        Restart = "on-failure";
        UMask = "0077";
        # RTNETLINK supplies existing kernel events.  AF_INET/AF_INET6 are
        # deliberately unavailable: this service has no packet path.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/run/usb-downlink-observer" ];
        IPAddressDeny = "any";
      };
    };
  };
}
