{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "prometheus-usb-downlink-fixture";
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eno1";
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
  centerHorizon = {
    node.behavesAs = {
      center = true;
      router = false;
    };
  };
  center = lib.nixosSystem {
    inherit system;
    specialArgs.horizon = centerHorizon;
    modules = [ ../../modules/nixos/network/networkd.nix ];
  };
  usbRuleName = "05-usb-eth";
  wanRuleName = "10-wan";
  usb = router.config.systemd.network.networks.${usbRuleName};
  usbAdapter = {
    Name = "enp199s0f0u1";
    Type = "ether";
    Property = "ID_BUS=usb";
  };
  internalWan = {
    Name = "eno1";
    Type = "ether";
    Property = "ID_BUS=pci";
  };
  matchesUsbRule = link:
    link.Type == usb.matchConfig.Type
    && link.Property == usb.matchConfig.Property
    && link.Name != "eno1";
  centerUsbRuleName = "05-usb-eth";
  centerMainRuleName = "10-main-eth";
  centerUsb = center.config.systemd.network.networks.${centerUsbRuleName};
in
assert lib.assertMsg (usb.matchConfig.Property == "ID_BUS=usb")
  "the USB LAN rule must select the stable USB udev bus role";
assert lib.assertMsg (usb.matchConfig.Name == "!eno1")
  "USB LAN binding must explicitly exclude the declared WAN without selecting a USB name";
assert lib.assertMsg (!(usb.matchConfig ? Driver))
  "USB LAN binding must not require ID_NET_DRIVER during rename";
assert lib.assertMsg (matchesUsbRule usbAdapter)
  "a USB Ethernet adapter must match the LAN bridge rule";
assert lib.assertMsg (!matchesUsbRule internalWan)
  "an internal PCI Ethernet WAN NIC must not match the USB LAN bridge rule";
assert lib.assertMsg (usbRuleName < wanRuleName)
  "the USB role rule must sort before the Ethernet WAN/catch-all rule";
assert lib.assertMsg (usb.networkConfig.Bridge == "br-lan")
  "the selected USB LAN interface must remain a bridge port";
assert lib.assertMsg (usb.networkConfig.ConfigureWithoutCarrier)
  "the bridge binding must survive hotplug before carrier";
assert lib.assertMsg (centerUsb.matchConfig.Property == "ID_BUS=usb")
  "the generic center USB rule must use the stable USB udev bus role";
assert lib.assertMsg (!(centerUsb.matchConfig ? Driver))
  "the generic center USB rule must not require ID_NET_DRIVER";
assert lib.assertMsg (centerUsbRuleName < centerMainRuleName)
  "the generic USB rule must sort before the Ethernet catch-all";
pkgs.runCommand "router-usb-downlink-binding" { } ''
  touch "$out"
''
