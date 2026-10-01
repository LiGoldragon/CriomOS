{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "router-yggdrasil-ndp-fixture";
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
        ssid = "router-yggdrasil-ndp-fixture";
        country = "MX";
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
  rules = cfg.networking.nftables.tables.nixos-fw.content;
in
assert lib.assertMsg (
  cfg.networking.firewall.enable && cfg.networking.firewall.backend == "nftables"
) "overlay discovery uses the shared firewall";
assert lib.assertMsg (
  lib.hasInfix "nd-neighbor-solicit" cfg.networking.nftables.tables.router-upstream-boundary.content
  && lib.hasInfix "nd-neighbor-advert" cfg.networking.nftables.tables.router-upstream-boundary.content
) "link-local neighbour discovery remains admitted";
assert lib.assertMsg
  (lib.hasInfix "ip6 saddr fe80::/64 ip6 daddr fe80::/64 udp dport 9001 accept" rules)
  "Yggdrasil multicast retains its link-local scope";
assert lib.assertMsg (lib.hasInfix "policy drop" rules)
  "unsolicited upstream packets retain default-drop policy";
pkgs.runCommand "router-yggdrasil-ndp-check" { } "touch $out"
