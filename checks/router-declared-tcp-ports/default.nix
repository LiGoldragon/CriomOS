{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "fixture-cluster";
    node = {
      name = "router-declared-tcp-ports-fixture";
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eno1";
        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "wifi4";
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
  rules = router.config.networking.nftables.ruleset;
  rulesFile = pkgs.writeText "router-declared-tcp-ports-ruleset" rules;
in
assert lib.assertMsg
  (lib.hasInfix ''tcp dport 80 accept comment "Allow declared TCP service port 80"'' rules)
  "router nftables must compose the declared Nix cache TCP port";
assert lib.assertMsg
  (lib.hasInfix ''tcp dport 7440 accept comment "Allow declared TCP service port 7440"'' rules)
  "router nftables must compose every declared TCP service port";
assert lib.assertMsg (lib.hasInfix ''iifname "eno1" counter drop'' rules)
  "declared service ports must be admitted before the router WAN default drop";
pkgs.runCommand "router-declared-tcp-ports-check" { } ''
  declared_line=$(${pkgs.gnugrep}/bin/grep -nF 'tcp dport 80 accept comment "Allow declared TCP service port 80"' ${rulesFile} | ${pkgs.coreutils}/bin/cut -d: -f1)
  drop_line=$(${pkgs.gnugrep}/bin/grep -nF 'iifname "eno1" counter drop' ${rulesFile} | ${pkgs.coreutils}/bin/cut -d: -f1)
  test "$declared_line" -lt "$drop_line"
  touch "$out"
''
