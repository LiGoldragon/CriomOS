# Installs the USB Ethernet role classification (usb-ethernet-role.nix) on
# every node, and gives an uplink, a tether, the network it asks for.
#
# The rule is its own rules file, 76-, so it runs after
# 75-net-description.rules imported the USB properties and before any rule
# in 99-local.rules that reads the role.
#
# networkd owns every uplink on every node, matched by the role itself: a
# DHCP client whose routes carry the uplink route metric, on a link in the
# uplink group, which a router's firewall names. Where NetworkManager also
# runs, it leaves the uplinks alone, and decides by itself when the node is
# online.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkDefault mkIf mkOption types;
  usbEthernet = import ./usb-ethernet-role.nix { inherit lib; };
  rules = pkgs.writeTextDir "lib/udev/rules.d/76-criomos-usb-ethernet-role.rules" usbEthernet.classificationRules;
  uplink = config.criomos.usbEthernet.uplink;
  networkManager = config.networking.networkmanager.enable;
in
{
  options.criomos.usbEthernet.uplink = {
    routeMetric = mkOption {
      type = types.ints.unsigned;
      default = 50;
      description = ''
        Metric of the routes a USB uplink (a tether) brings, IPv4 and IPv6.
        Below every other wired or wireless default route, so a plugged-in
        phone carries the node's traffic; a router raises it above its WAN,
        so the tether is the backup.
      '';
    };
    linkGroup = mkOption {
      type = types.ints.between 1 2147483647;
      default = 64;
      description = "Kernel link group of every USB uplink, by which a firewall names the uplinks.";
    };
  };

  config = {
    services.udev.packages = [ rules ];

    services.udev.extraRules = mkIf networkManager ''
      ${usbEthernet.udevMatch { role = "uplink"; }}, ENV{NM_UNMANAGED}="1"
    '';

    systemd.network = {
      enable = true;
      wait-online.enable = mkIf (networkManager && !config.networking.useNetworkd) (mkDefault false);

      networks."04-usb-uplink" = {
        matchConfig = usbEthernet.networkdMatch { role = "uplink"; };
        networkConfig.DHCP = "yes";
        dhcpV4Config.RouteMetric = uplink.routeMetric;
        ipv6AcceptRAConfig.RouteMetric = uplink.routeMetric;
        linkConfig = {
          Group = uplink.linkGroup;
          RequiredForOnline = "no";
        };
      };
    };
  };
}
