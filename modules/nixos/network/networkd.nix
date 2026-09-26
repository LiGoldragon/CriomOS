{
  lib,
  pkgs,
  horizon,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;

  hotplugSubnet = "10.47.0";
  usbEthernet = import ./usb-ethernet-role.nix { inherit lib; };
  declaresUsbDownlink = builtins.any (
    capability: builtins.isAttrs capability && (capability.kind or null) == "usbDownlink"
  ) (horizon.node.capabilities or [ ]);

in
# Router nodes provide their own networkd config with bridge/hostapd
mkIf (behavesAs.center && !behavesAs.router) {
  networking.useNetworkd = true;
  systemd.network.enable = true;

  # Main NIC — DHCP client for internet
  systemd.network.networks."10-main-eth" = {
    matchConfig.Type = "ether";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    linkConfig.RequiredForOnline = "routable";
  };

  # USB ethernet dongles act as router and serve DHCP.  This sorts before the
  # broad main-Ethernet DHCP client rule: networkd selects the first match.
  # ID_NET_DRIVER can be absent while an adapter is renamed, but the udev USB
  # bus role remains available.  A node that declares the UsbDownlink
  # capability gets its declared downlink from usb-downlink.nix instead.
  systemd.network.networks."05-usb-eth" = mkIf (!declaresUsbDownlink) {
    matchConfig = usbEthernet.networkdMatch { };
    networkConfig = {
      Address = "${hotplugSubnet}.1/24";
      DHCPServer = true;
      IPMasquerade = "ipv4";
    };
    dhcpServerConfig = {
      PoolOffset = 10;
      PoolSize = 200;
      DNS = "${hotplugSubnet}.1";
      EmitDNS = true;
      EmitRouter = true;
    };
    linkConfig.RequiredForOnline = "no";
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  services.resolved = {
    enable = true;
    settings.Resolve.FallbackDNS = [
      "1.1.1.1"
      "9.9.9.9"
    ];
  };
}
