{ inputs, pkgs, ... }:

# The router record's radio facts reach hostapd as declared: the regulatory
# country reaches hostapd and the kernel regulatory domain unchanged, and a
# record without it fails evaluation instead of falling back to a default;
# Horizon's WlanStandard spelling enables the matching standard; hostapd logs
# at debug level.
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
        secrets.sopsFiles = {
          fixtureWifiPassword = builtins.toFile "fixture-wifi-password" "";
          fixtureBackupWifiPassword = builtins.toFile "fixture-backup-wifi-password" "";
        };
      };
      constants = inputs.criomos-lib.lib.constants;
    };
    modules = [
      inputs.sops-nix.nixosModules.sops
      ../../modules/nixos/router/default.nix
      ../../modules/nixos/network/usb-ethernet-role-rule.nix
      { nixpkgs.config.allowUnfree = true; }
    ];
  };

  declared = (routerFor (routerInterfacesWith { country = "MX"; })).config;
  radio = declared.services.hostapd.radios.wlan0;
  withBackup =
    (routerFor (routerInterfacesWith {
      country = "MX";
      backupWireless = {
        interface = "wlan1";
        networkName = "router-backup-fixture";
        band = "2g";
        channel = 6;
        passwordReference = "fixtureBackupWifiPassword";
      };
    })).config;
  services = declared.systemd.services;
  primary = services.hostapd;
  backup = withBackup.systemd.services.hostapd-backup-wireless;
  bridgeDevice = ''sys-subsystem-net-devices-br\x2dlan.device'';
  networkd = "systemd-networkd.service";
  radioDevice = "sys-subsystem-net-devices-wlan0.device";
  backupDevice = "sys-subsystem-net-devices-wlan1.device";
  bridgeFirst = service:
    builtins.elem networkd service.after
    && builtins.elem networkd service.wants
    && builtins.elem bridgeDevice service.after
    && builtins.elem bridgeDevice service.bindsTo
    && !builtins.elem networkd service.requires
    && !builtins.elem networkd service.bindsTo
    && !(lib.any (dependency: builtins.elem dependency [
      "network-online.target"
      "systemd-networkd-wait-online.service"
    ]) (service.after ++ service.wants ++ service.requires ++ service.bindsTo));
  bridge = declared.systemd.network.netdevs."20-br-lan".netdevConfig;
  bridgeNetwork = declared.systemd.network.networks."40-br-lan";
  missing = builtins.tryEval
    (routerFor (routerInterfacesWith { })).config.services.hostapd.radios.wlan0.countryCode;
in
assert lib.assertMsg (radio.countryCode == "MX")
  "hostapd country_code must be the declared routerInterfaces.country";
assert lib.assertMsg (builtins.elem "cfg80211.ieee80211_regdom=MX" declared.boot.kernelParams)
  "the kernel regulatory domain must be the declared routerInterfaces.country";
assert lib.assertMsg (radio.networks.wlan0.logLevel == 1)
  "hostapd must log at debug level so authentication and SAE failures reach the journal";
assert lib.assertMsg (radio.wifi4.enable && !radio.wifi6.enable)
  "the projected WlanStandard spelling Wifi4 must enable 802.11n";
assert lib.assertMsg ((radio.settings.ieee80211n or false) == true)
  "hostapd must be configured with ieee80211n";
assert lib.assertMsg (!missing.success)
  "a router record without a country must fail evaluation";
assert lib.assertMsg (
  declared.systemd.network.enable
  && bridge.Name == "br-lan"
  && bridge.Kind == "bridge"
  && bridgeNetwork.networkConfig.ConfigureWithoutCarrier
  && radio.networks.wlan0.settings.bridge == "br-lan"
) "networkd must independently create br-lan, and hostapd must use it";
assert lib.assertMsg (
  declared.services.hostapd.enable
  && bridgeFirst primary
  && builtins.elem radioDevice primary.after
  && builtins.elem radioDevice primary.bindsTo
  && builtins.elem "multi-user.target" primary.wantedBy
  && !primary.restartIfChanged
  && !primary.stopIfChanged
) "primary hostapd must wait on br-lan without losing its radio, boot, or switch guards";
assert lib.assertMsg (
  bridgeFirst backup
  && builtins.elem backupDevice backup.after
  && builtins.elem backupDevice backup.bindsTo
  && builtins.elem backupDevice backup.wantedBy
  && !backup.restartIfChanged
  && !backup.stopIfChanged
) "backup hostapd must not win bridge ownership, and its USB lifecycle must be retained";
assert lib.assertMsg (
  !(builtins.hasAttr "hostapd-backup-wireless" services)
  && builtins.elem bridgeDevice services.kea-dhcp4-server.bindsTo
  && builtins.elem "hostapd.service" services.kea-dhcp4-server.partOf
  && builtins.elem "hostapd.service" services.kea-dhcp4-server.after
  && !builtins.elem "kea-dhcp4-server.service" primary.after
  && !builtins.elem "kea-dhcp4-server.service" primary.requires
) "backup must remain optional; Kea must wait for hostapd, never the reverse";

pkgs.runCommand "router-wifi-radio-check" { } ''
  touch "$out"
''
