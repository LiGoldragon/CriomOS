# Evaluation policy for the USB uplink vendors of the UsbDownlink feature
# (network/usb-downlink.nix): a listed vendor's device is an uplink with DHCP,
# before the downlink rule; every other USB Ethernet device stays a downlink.
{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  constants = inputs.criomos-lib.lib.constants;
  downlink = network: {
    kind = "usbDownlink";
    ipv4Network = network;
  };

  edge =
    capabilities:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants;
        horizon.node = {
          inherit capabilities;
          enableNetworkManager = true;
          behavesAs = {
            router = false;
            center = false;
          };
        };
      };
      modules = [
        ../../modules/nixos/network/usb-downlink.nix
        ../../modules/nixos/network/resolver.nix
        ../../modules/nixos/network/networkd.nix
        { networking.networkmanager.enable = true; }
      ];
    };

  networks = (edge [ (downlink "10.44.0.0/24") ]).config.systemd.network.networks;
  uplink = networks."01-usb-uplink-18d1";
in
assert lib.assertMsg (
  uplink.matchConfig == {
    Type = "ether";
    Property = [
      "ID_BUS=usb"
      "ID_VENDOR_ID=18d1"
    ];
  }
) "a listed vendor's USB Ethernet device gets the uplink rule, matched by bus and vendor";
assert lib.assertMsg (
  "01-usb-uplink-18d1" < "05-usb-downlink"
) "the uplink rule sorts before the downlink rule, so networkd applies it first";
assert lib.assertMsg (uplink.networkConfig.DHCP == "yes") "the uplink asks the phone for an address";
assert lib.assertMsg (
  uplink.dhcpV4Config.RouteMetric < 600 && uplink.ipv6AcceptRAConfig.RouteMetric < 600
) "the uplink's routes sit below Wi-Fi's (NetworkManager metric 600)";
assert lib.assertMsg (!(uplink.networkConfig ? Bridge)) "the uplink never joins the downlink bridge";
assert lib.assertMsg (
  networks."05-usb-downlink".networkConfig.Bridge == "br-downlink"
) "every other USB Ethernet device stays a downlink";
pkgs.runCommand "usb-uplink-policy" { } "touch $out"
