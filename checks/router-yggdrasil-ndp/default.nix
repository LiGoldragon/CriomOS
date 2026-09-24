{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "router-yggdrasil-ndp-fixture";
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eno1";
        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "wifi4";
        ssid = "router-yggdrasil-ndp-fixture";
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
  rules = router.config.networking.nftables.ruleset;
  scopedNdp = ''iifname "eno1" ip6 saddr fe80::/64 ip6 daddr { fe80::/64, ff02::/16 } icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept'';
in
assert lib.assertMsg (lib.hasInfix scopedNdp rules)
  "router WAN must admit link-local neighbour discovery before Yggdrasil ports";
assert lib.assertMsg (
  !(lib.hasInfix ''iifname "eno1" meta l4proto ipv6-icmp accept'' rules)
) "router WAN must not broadly admit every IPv6 ICMP packet";
assert lib.assertMsg (lib.hasInfix ''iifname "eno1" counter drop'' rules)
  "router WAN must retain its default-drop boundary";

pkgs.runCommand "router-yggdrasil-ndp-check" { } ''
  touch "$out"
''
