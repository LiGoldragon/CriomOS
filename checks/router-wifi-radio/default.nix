{ inputs, pkgs, ... }:

# The router record's radio facts reach hostapd as declared: Horizon's
# WlanStandard spelling enables the matching standard, and hostapd logs at
# debug level.
let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  routerInterfacesWith = extra: {
    wan = "eno1";
    wlan = "wlan0";
    wlanBand = "2g";
    wlanChannel = 6;
    wlanStandard = "Wifi4";
    ssid = "router-wifi-radio-fixture";
    wpa3SaePasswordReference = "fixtureWifiPassword";
  } // extra;

  routerFor = routerInterfaces: lib.nixosSystem {
    inherit system;
    specialArgs = {
      horizon = {
        cluster = "goldragon";
        node = {
          name = "router-wifi-radio-fixture";
          behavesAs.router = true;
          network = { inherit routerInterfaces; };
        };
      };
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

  declared = (routerFor (routerInterfacesWith { country = "MX"; })).config;
  radio = declared.services.hostapd.radios.wlan0;
in
assert lib.assertMsg (radio.networks.wlan0.logLevel == 1)
  "hostapd must log at debug level so authentication and SAE failures reach the journal";
assert lib.assertMsg (radio.wifi4.enable && !radio.wifi6.enable)
  "the projected WlanStandard spelling Wifi4 must enable 802.11n";
assert lib.assertMsg ((radio.settings.ieee80211n or false) == true)
  "hostapd must be configured with ieee80211n";

pkgs.runCommand "router-wifi-radio-check" { } ''
  touch "$out"
''
