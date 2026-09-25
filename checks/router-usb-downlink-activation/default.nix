{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "router-usb-downlink-activation-fixture";
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eno1";
        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "wifi4";
        ssid = "router-usb-downlink-activation-fixture";
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
  service = router.config.systemd.services.router-usb-ethernet-reconcile;
  usbNetwork = router.config.systemd.network.networks."30-usb-eth";
in
assert lib.assertMsg (service.wantedBy == [ "multi-user.target" ])
  "router USB reconciliation must run on a generation switch";
assert lib.assertMsg (service.after == [ "systemd-networkd.service" ])
  "router USB reconciliation must wait for networkd";
assert lib.assertMsg (service.serviceConfig.Type == "oneshot")
  "router USB reconciliation must be bounded";
assert lib.assertMsg (usbNetwork.matchConfig.Property == [ "ID_BUS=usb" ])
  "router USB downlinks must match their stable udev bus property";
assert lib.assertMsg (usbNetwork.matchConfig.Name == "!eno1")
  "router USB downlinks must exclude the declared WAN";

pkgs.runCommand "router-usb-downlink-activation-check"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    mkdir -p sys/class/net/{enp-usb,eno1} mock
    cat > mock/networkctl <<'EOF'
    #!${pkgs.bash}/bin/bash
    echo "$*" >> "$TEST_LOG"
    EOF
    cat > mock/udevadm <<'EOF'
    #!${pkgs.bash}/bin/bash
    case "$*" in
      *enp-usb) echo ID_BUS=usb ;;
      *eno1) echo ID_BUS=pci ;;
    esac
    EOF
    chmod +x mock/networkctl mock/udevadm
    export PATH="$PWD/mock:$PATH"
    export SYS_CLASS_NET="$PWD/sys/class/net"
    export TEST_LOG="$PWD/networkctl.log"

    ${pkgs.bash}/bin/bash ${../../modules/nixos/router/usb-ethernet-reconcile.sh} eno1
    test "$(cat "$TEST_LOG")" = $'reload\nreconfigure enp-usb'
    touch "$out"
  ''
