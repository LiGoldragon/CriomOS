{ pkgs, lib, ... }:
let
  script = ../../modules/nixos/watchdog-witness.sh;
  node = (import ../../fixtures/horizon-node.nix { inherit lib; }).node;
  witnessNode = node {
    capabilities = [ { kind = "watchdogWitness"; scope = "router"; } ];
    behavesAs.router = true;
  };
  system = lib.nixosSystem {
    inherit pkgs;
    specialArgs = { horizon = { node = witnessNode; }; };
    modules = [ ../../modules/nixos/watchdog-witness.nix ];
  };
  run = pkgs.writeShellScript "watchdog-witness-fixture-check" ''
    set -eu
    fixture=$(mktemp -d)
    trap 'rm -rf "$fixture"' EXIT
    fakebin="$fixture/bin"; mkdir -p "$fakebin"
    cat > "$fakebin/systemd-cat" <<'CAT'
#!/bin/sh
cat
CAT
    chmod +x "$fakebin/systemd-cat"
    check() {
      identity=$1; status=$2; expected=$3
      d="$fixture/$RANDOM"; mkdir -p "$d"
      printf '%s\n' "$identity" > "$d/identity"
      printf '%s\n' "$status" > "$d/bootstatus"
      out="$d/out"
      if PATH="$fakebin:$PATH" CRIOMOS_WATCHDOG_IDENTITY_PATH="$d/identity" CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$d/bootstatus" ${pkgs.bash}/bin/bash ${script} >"$out" 2>"$d/err"; then :; else
        test "$expected" = failure
        return
      fi
      grep -F "RAW_BOOTSTATUS=$status" "$out" >/dev/null
      grep -F "CLASSIFICATION=$expected" "$out" >/dev/null
    }
    check 'SP5100 TCO timer' 0 'unknown/inconclusive'
    check 'SP5100 TCO timer' 32 watchdog-fired
    check 'SP5100 TCO timer' 96 watchdog-fired
    check 'SP5100 TCO timer' malformed failure
    check 'SP5100 TCO timer' 0x20 failure
    check 'Other watchdog' 32 failure
  '';
in
assert lib.assertMsg (system.config.systemd.services.criomos-watchdog-witness.wantedBy == [ "multi-user.target" ]) "watchdog witness is boot-target triggered";
assert lib.assertMsg (system.config.systemd.services.criomos-watchdog-witness.after == [ "systemd-modules-load.service" "dev-watchdog0.device" ]) "watchdog witness follows the device event";
assert lib.assertMsg (system.config.systemd.services.criomos-watchdog-witness.serviceConfig.PrivateDevices) "watchdog witness cannot open the watchdog device";
pkgs.runCommand "watchdog-witness-check" { } ''
  ${run}
  touch $out
''
