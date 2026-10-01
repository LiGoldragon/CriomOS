{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "fixture-cluster";
    node = {
      name = "router-declared-tcp-ports-fixture";
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
        wlanStandard = "Wifi4";
        country = "US";
        ssid = "router-declared-tcp-ports-fixture";
        wpa3SaePasswordReference = "routerWifiSaePasswords";
      };
    };
  };
  router = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit horizon;
      inputs = inputs // {
        secrets.sopsFiles.routerWifiSaePasswords = builtins.toFile "router-wifi-password" "fixture";
      };
      constants = inputs.criomos-lib.lib.constants;
    };
    modules = [
      inputs.sops-nix.nixosModules.sops
      ../../modules/nixos/router/default.nix
      {
        nixpkgs.config.allowUnfree = true;
        networking.firewall.allowedTCPPorts = [
          80
          7440
        ];
      }
    ];
  };
  cfg = router.config;
  rules = cfg.networking.nftables.tables.nixos-fw.content;
in
assert lib.assertMsg (
  cfg.networking.firewall.allowedTCPPorts == [
    80
    7440
  ]
) "every declared TCP service port reaches the common firewall";
assert lib.assertMsg (lib.hasInfix "tcp dport { 80, 7440 } accept" rules)
  "the generated nftables rules admit the declared services";
assert lib.assertMsg (lib.hasInfix "policy drop" rules)
  "other unsolicited upstream services remain closed";
pkgs.runCommand "router-declared-tcp-ports-check" { } "touch $out"
