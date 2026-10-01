{
  lib,
  pkgs,
  horizon,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;

  declaresUsbDownlink = builtins.any (
    capability: builtins.isAttrs capability && (capability.kind or null) == "usbDownlink"
  ) (horizon.node.capabilities or [ ]);

in
# Router nodes provide their own networkd config with bridge/hostapd
mkIf (behavesAs.center && !behavesAs.router && !declaresUsbDownlink) {
  networking.useNetworkd = true;
  systemd.network.enable = true;

  # Main NIC — DHCP client for internet
  systemd.network.networks."10-main-eth" = {
    matchConfig = {
      Type = "ether";
      Property = "ID_BUS=pci";
    };
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    linkConfig.RequiredForOnline = "routable";
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
