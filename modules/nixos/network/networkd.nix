{
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;

  # USB-Ethernet hotplug subnet is a CriomOS implementation convention
  # (different concept from the cluster LAN). It stays in-module until
  # a horizon shape (AccessPortPolicy / HotplugNetwork per report 119
  # §2) lands.
  hotplugSubnet = "10.47.0";

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

  # USB ethernet dongles — act as router, serve DHCP
  systemd.network.networks."20-usb-eth" = {
    matchConfig = {
      Type = "ether";
      Driver = "cdc_ether r8152 ax88179_178a asix";
    };
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
    settings.Resolve.FallbackDNS = constants.network.resolver.fallbacks;
  };
}
