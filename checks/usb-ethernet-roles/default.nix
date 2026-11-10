# The USB Ethernet roles (network/usb-ethernet-role.nix): the classification
# rule is valid udev and tells a tether from a dongle by the kernel's own
# test; a networkd node gives an uplink its DHCP file before the downlink
# rule; a NetworkManager node leaves the uplink to NetworkManager.
{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  usbEthernet = import ../../modules/nixos/network/usb-ethernet-role.nix { inherit lib; };

  node =
    { networkManager }:
    (lib.nixosSystem {
      inherit system;
      specialArgs.horizon.node.behavesAs = {
        center = !networkManager;
        router = false;
      };
      modules = [
        ../../modules/nixos/network/usb-ethernet-role-rule.nix
        ../../modules/nixos/network/networkd.nix
        { networking.networkmanager.enable = networkManager; }
      ];
    }).config;
  networkdNode = node { networkManager = false; };
  networkManagerNode = node { networkManager = true; };
  uplink = networkdNode.systemd.network.networks."04-usb-uplink";
  rulesFile = pkgs.writeText "76-criomos-usb-ethernet-role.rules" usbEthernet.classificationRules;
in
assert lib.assertMsg (
  uplink.matchConfig == {
    Type = "ether";
    Property = [
      "ID_BUS=usb"
      "CRIOMOS_USB_ETHERNET_ROLE=uplink"
    ];
  }
) "a networkd node matches an uplink by the USB bus and the uplink role";
assert lib.assertMsg (uplink.networkConfig.DHCP == "yes") "a networkd node asks the tether for an address";
assert lib.assertMsg (!(uplink.networkConfig ? Bridge)) "an uplink never joins a bridge";
assert lib.assertMsg (
  "04-usb-uplink" < "05-usb-eth"
) "the uplink file sorts before the downlink rule";
assert lib.assertMsg (
  networkdNode.systemd.network.networks."05-usb-eth".matchConfig.Property == [
    "ID_BUS=usb"
    "CRIOMOS_USB_ETHERNET_ROLE=downlink"
  ]
) "the center node's USB rule takes downlinks only";
assert lib.assertMsg (
  !(networkManagerNode.systemd.network.networks ? "04-usb-uplink")
) "a NetworkManager node leaves the uplink to NetworkManager, with no networkd file";
assert lib.assertMsg (
  builtins.any (package: lib.hasInfix "usb-ethernet-role" (toString package)) networkManagerNode.services.udev.packages
) "the classification rule is installed on every node";
pkgs.runCommand "usb-ethernet-roles" { nativeBuildInputs = [ pkgs.systemd pkgs.bash ]; } ''
  set -eu
  # The rule is valid udev.
  udevadm verify --no-style ${rulesFile}
  # The locally administered test, with udev's glob as the shell's: a
  # Pixel tether's MAC is locally administered, a dongle's is the vendor's.
  locallyAdministered() { case "$1" in ?[2367abef]:*) return 0 ;; *) return 1 ;; esac; }
  locallyAdministered 52:1d:84:30:b6:5f || { echo "the Pixel tether MAC must read as locally administered"; exit 1; }
  locallyAdministered 5a:47:10:23:ef:12 || { echo "a randomised tether MAC must read as locally administered"; exit 1; }
  ! locallyAdministered 00:0e:c6:33:4f:97 || { echo "the ASIX dongle MAC must not read as locally administered"; exit 1; }
  ! locallyAdministered c8:53:09:7e:83:ab || { echo "a vendor MAC must not read as locally administered"; exit 1; }
  grep -q 'ID_USB_DRIVER}=="ipheth", ENV{CRIOMOS_USB_ETHERNET_ROLE}="uplink"' ${rulesFile}
  grep -q 'ID_USB_DRIVER}=="cdc_ether|cdc_ncm|rndis_host", ATTR{address}=="?\[2367abef\]:\*", ENV{CRIOMOS_USB_ETHERNET_ROLE}="uplink"' ${rulesFile}
  touch "$out"
''
