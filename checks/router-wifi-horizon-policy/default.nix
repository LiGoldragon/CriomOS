{ pkgs, ... }:

let
  inherit (pkgs) lib;
  routerModule = builtins.readFile ../../modules/nixos/router/default.nix;
in
assert lib.assertMsg (
  !(lib.hasInfix "countryCode = \"PL\"" routerModule)
) "router wifi country code must come from horizon.node.routerInterfaces";
assert lib.assertMsg (
  !(lib.hasInfix "ssid = \"criome\"" routerModule)
) "router wifi network name must come from horizon.node.routerInterfaces";
assert lib.assertMsg
  (lib.hasInfix "countryCode = routerInterfaces.wirelessCountryCode" routerModule)
  "router wifi country code must use routerInterfaces.wirelessCountryCode";
assert lib.assertMsg (lib.hasInfix "ssid = routerInterfaces.wirelessNetworkName" routerModule)
  "router wifi network name must use routerInterfaces.wirelessNetworkName";

pkgs.runCommand "router-wifi-horizon-policy-check" { } ''
  touch "$out"
''
