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
  (lib.hasInfix "countryCode = wirelessCountryCode" routerModule)
  "router wifi country code must use the resolved wirelessCountryCode";
assert lib.assertMsg (lib.hasInfix "ssid = wirelessNetworkName" routerModule)
  "router wifi network name must use the resolved wirelessNetworkName";

assert lib.assertMsg (
  !(lib.hasInfix "or \"PL\"" routerModule) && !(lib.hasInfix "routerInterfaces.wirelessCountryCode" routerModule)
) "router wifi country code must have no fallback: a missing country is an evaluation error";
assert lib.assertMsg (lib.hasInfix "cfg80211.ieee80211_regdom=\${wirelessCountryCode}" routerModule)
  "the kernel regulatory domain must come from the declared country";
assert lib.assertMsg (lib.hasInfix "logLevel = hostapdLogLevel" routerModule)
  "hostapd's logger level must be declared";
assert lib.assertMsg (lib.hasInfix "wlanStandard == \"Wifi4\"" routerModule)
  "router wifi standard must match Horizon's projected WlanStandard spelling";

pkgs.runCommand "router-wifi-horizon-policy-check" { } ''
  touch "$out"
''
