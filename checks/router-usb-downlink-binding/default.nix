{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "prometheus-usb-downlink-fixture";
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eno1";
        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "wifi4";
        ssid = "prometheus-usb-downlink-fixture";
        country = "PL";
        wpa3SaePasswordReference = "fixtureWifiPassword";
        usbLanMacAddress = "00:0e:c6:ad:21:5d";
      };
    };
  };
  router = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit horizon;
      inputs = inputs // {
        secrets.sopsFiles.fixtureWifiPassword = builtins.toFile "fixture-wifi-password" "";
      };
      constants = inputs.criomos-lib.lib.constants;
    };
    modules = [
      inputs.sops-nix.nixosModules.sops
      ../../modules/nixos/router/default.nix
      { nixpkgs.config.allowUnfree = true; }
    ];
  };
  usb = router.config.systemd.network.networks."30-usb-eth";
in
assert lib.assertMsg (usb.matchConfig.MACAddress == "00:0e:c6:ad:21:5d")
  "the declared USB LAN MAC must bind the downlink through interface rename";
assert lib.assertMsg (!(usb.matchConfig ? Name))
  "USB LAN binding must not depend on the transient kernel interface name";
assert lib.assertMsg (usb.networkConfig.Bridge == "br-lan")
  "the selected USB LAN interface must remain a bridge port";
assert lib.assertMsg (usb.networkConfig.ConfigureWithoutCarrier)
  "the bridge binding must survive hotplug before carrier";
pkgs.runCommand "router-usb-downlink-binding" { } ''
  touch "$out"
''
