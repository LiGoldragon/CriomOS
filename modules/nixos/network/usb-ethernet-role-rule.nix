# Installs the USB Ethernet role classification (usb-ethernet-role.nix) on
# every node, and gives an uplink, a tether, the network it asks for.
#
# The rule is its own rules file, 76-, so it runs after
# 75-net-description.rules imported the USB properties and before any rule
# in 99-local.rules that reads the role.
#
# Where NetworkManager runs it manages an uplink as any wired connection:
# nothing here marks a tether unmanaged. Where it does not, networkd gives
# the uplink one DHCP client file, sorted before every USB rule.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  usbEthernet = import ./usb-ethernet-role.nix { inherit lib; };
  rules = pkgs.writeTextDir "lib/udev/rules.d/76-criomos-usb-ethernet-role.rules" usbEthernet.classificationRules;
in
{
  services.udev.packages = [ rules ];

  systemd.network.networks."04-usb-uplink" =
    lib.mkIf (config.systemd.network.enable && !config.networking.networkmanager.enable)
      {
        matchConfig = usbEthernet.networkdMatch { role = "uplink"; };
        networkConfig.DHCP = "yes";
        linkConfig.RequiredForOnline = "no";
      };
}
