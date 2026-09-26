{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  horizon = {
    cluster = "goldragon";
    node = {
      name = "router-wan-recovery-fixture";
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eno1";
        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "Wifi4";
        ssid = "router-wan-recovery-fixture";
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
  service = router.config.systemd.services.router-wan-lease-recovery;
  timer = router.config.systemd.timers.router-wan-lease-recovery;
in
assert lib.assertMsg (service.serviceConfig.Type == "oneshot")
  "WAN recovery must be a bounded oneshot service";
assert lib.assertMsg (lib.hasInfix "eno1" service.serviceConfig.ExecStart)
  "WAN recovery must target the router's declared WAN interface";
assert lib.assertMsg (timer.timerConfig.OnUnitInactiveSec == "2min")
  "WAN recovery must recheck after a late upstream DHCP server appears";

pkgs.runCommand "router-wan-recovery-check"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail
    mkdir -p mock
    cat > mock/ip <<'EOF'
    #!${pkgs.bash}/bin/bash
    if [ "$1 $2 $3 $4 $5" = "-o link show dev eno1" ]; then
      if [ "''${TEST_CARRIER:-0}" = 1 ]; then
        echo '2: eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'
      else
        echo '2: eno1: <BROADCAST,MULTICAST,UP> mtu 1500'
      fi
    elif [ "$1 $2 $3 $4 $5 $6" = "-4 route show default dev eno1" ]; then
      if [ "''${TEST_ROUTE:-0}" = 1 ]; then
        echo 'default via 10.44.0.1 dev eno1'
      fi
    else
      exit 2
    fi
    EOF
    cat > mock/networkctl <<'EOF'
    #!${pkgs.bash}/bin/bash
    echo "$*" >> "$TEST_LOG"
    if [ "''${TEST_FAIL:-0}" = 1 ]; then exit 1; fi
    EOF
    chmod +x mock/ip mock/networkctl
    export PATH="$PWD/mock:$PATH"
    export TEST_LOG="$PWD/networkctl.log"
    : > "$TEST_LOG"

    TEST_CARRIER=0 TEST_ROUTE=0 ${pkgs.bash}/bin/bash ${../../modules/nixos/router/wan-lease-recovery.sh} eno1
    test ! -s "$TEST_LOG"

    TEST_CARRIER=1 TEST_ROUTE=1 ${pkgs.bash}/bin/bash ${../../modules/nixos/router/wan-lease-recovery.sh} eno1
    test ! -s "$TEST_LOG"

    TEST_CARRIER=1 TEST_ROUTE=0 ${pkgs.bash}/bin/bash ${../../modules/nixos/router/wan-lease-recovery.sh} eno1
    test "$(cat "$TEST_LOG")" = 'reconfigure eno1'

    if TEST_CARRIER=1 TEST_ROUTE=0 TEST_FAIL=1 ${pkgs.bash}/bin/bash ${../../modules/nixos/router/wan-lease-recovery.sh} eno1; then
      echo 'failed reconfigure was hidden' >&2
      exit 1
    fi
    touch "$out"
  ''
