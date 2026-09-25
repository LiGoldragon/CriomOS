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

  # This must sort before 10-main-eth: networkd assigns the first matching
  # .network file, and 10-main-eth intentionally catches all Ethernet links.
  systemd.network.networks."05-usb-eth" = {
    matchConfig = {
      Type = "ether";
      Property = [ "ID_BUS=usb" ];
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
    settings.Resolve.FallbackDNS = [
      "1.1.1.1"
      "9.9.9.9"
    ];
  };
}
