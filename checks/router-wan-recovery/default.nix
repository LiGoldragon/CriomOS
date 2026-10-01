{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "router-wan-recovery-fixture";
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
        ssid = "router-wan-recovery-fixture";
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
  upstream = cfg.systemd.network.networks."10-upstream";
in
assert lib.assertMsg (
  upstream.matchConfig == {
    Type = "ether";
    Property = "ID_BUS=pci";
  }
) "late-upstream recovery uses the same hardware role as initial configuration";
assert lib.assertMsg (
  upstream.dhcpV4Config.MaxAttempts == "infinity"
) "networkd keeps requesting DHCP while the upstream server is late";
assert lib.assertMsg (
  !(cfg.systemd.timers ? router-wan-lease-recovery)
) "late DHCP recovery has no interface-reconfiguration polling timer";
assert lib.assertMsg (
  !cfg.systemd.services.systemd-networkd.restartIfChanged
) "activation preserves the live AP recovery path";
pkgs.runCommand "router-wan-recovery-check" { } "touch $out"
