{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  fixture = capabilities: lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = {
      constants = inputs.criomos-lib.lib.constants;
      horizon.node = {
        inherit capabilities;
        enableNetworkManager = true;
        behavesAs = { center = false; router = false; };
      };
    };
    modules = [
      ../../modules/nixos/network/networkd.nix
      ../../modules/nixos/network/usb-downlink.nix
      ../../modules/nixos/network/resolver.nix
      { networking.networkmanager.enable = true; }
    ];
  };
  sharing = (fixture [{ kind = "usbDownlink"; ipv4Network = "10.44.0.0/24"; }]).config;
  absent = (fixture []).config;
  upstream = sharing.systemd.network.networks."10-upstream";
  downstream = sharing.systemd.network.networks."05-usb-downlink";
in
assert lib.assertMsg (upstream.matchConfig == { Type = "ether"; Property = "ID_BUS=pci"; })
  "built-in Ethernet uplinks are selected by kind, with no interface name";
assert lib.assertMsg (downstream.matchConfig == { Type = "ether"; Property = "ID_BUS=usb"; })
  "USB Ethernet downlinks are selected by kind";
assert lib.assertMsg (!(upstream.networkConfig ? Bridge))
  "integrated Ethernet upstream candidates never join the downstream bridge";
assert lib.assertMsg (sharing.networking.nftables.enable && sharing.networking.firewall.enable)
  "sharing uses the common NixOS nftables firewall";
assert lib.assertMsg (!absent.services.kea.dhcp4.enable && !absent.networking.nat.enable)
  "USB sharing exists only through its capability";
pkgs.runCommand "usb-sharing-policy" {} "touch $out"
