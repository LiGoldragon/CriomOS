{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "prometheus-usb-downlink-fixture";
      behavesAs.router = true;
      capabilities = [
        {
          kind = "usbDownlink";
          ipv4Network = "10.18.0.0/24";
        }
      ];
      network.routerInterfaces = {

        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "wifi4";
        ssid = "prometheus-usb-downlink-fixture";
        country = "PL";
        wpa3SaePasswordReference = "fixtureWifiPassword";
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
  cfg = router.config;
  usb = cfg.systemd.network.networks."05-usb-downlink";
  upstream = cfg.systemd.network.networks."10-upstream";
in
assert lib.assertMsg (
  usb.matchConfig == {
    Type = "ether";
    Property = "ID_BUS=usb";
  }
) "USB Ethernet selection is independent of interface names";
assert lib.assertMsg (
  upstream.matchConfig == {
    Type = "ether";
    Property = "ID_BUS=pci";
  }
) "built-in Ethernet selection is independent of interface names";
assert lib.assertMsg (
  usb.networkConfig.Bridge == "br-lan" && !(upstream.networkConfig ? Bridge)
) "router USB downlinks join the LAN, integrated candidates never do";
assert lib.assertMsg (usb.networkConfig.ConfigureWithoutCarrier
) "USB attachment converges before carrier";
pkgs.runCommand "router-usb-downlink-binding" { } "touch $out"
