{ pkgs, lib, ... }:
let
  script = ../../modules/nixos/watchdog-witness.sh;
  node = (import ../../fixtures/horizon-node.nix { inherit lib; }).node;
  witnessNode = node {
    capabilities = [ ];
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
    check 'SP5100 TCO timer' 4294967296 failure
    d_missing="$fixture/missing"; mkdir -p "$d_missing"; printf 'SP5100 TCO timer\n' > "$d_missing/identity"
    if PATH="$fakebin:$PATH" CRIOMOS_WATCHDOG_IDENTITY_PATH="$d_missing/identity" CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$d_missing/status" ${pkgs.bash}/bin/bash ${script}; then exit 1; fi
    d_other="$fixture/other"; mkdir -p "$d_other"; printf 'Other watchdog\n' > "$d_other/identity"; printf '32\n' > "$d_other/bootstatus"
    PATH="$fakebin:$PATH" CRIOMOS_WATCHDOG_IDENTITY_PATH="$d_other/identity" CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$d_other/bootstatus" ${pkgs.bash}/bin/bash ${script} >"$d_other/out" 2>"$d_other/err"
    test ! -s "$d_other/out"; grep -F 'outside SP5100 witness scope' "$d_other/err" >/dev/null
  '';
in
assert lib.assertMsg (system.config.systemd.services.criomos-watchdog-witness.wantedBy == [ "dev-watchdog0.device" ]) "watchdog witness is boot-target triggered";
assert lib.assertMsg (system.config.systemd.services.criomos-watchdog-witness.after == [ "dev-watchdog0.device" ]) "watchdog witness follows the device event";
assert lib.assertMsg (system.config.systemd.services.criomos-watchdog-witness.serviceConfig.PrivateDevices) "watchdog witness cannot open the watchdog device";
pkgs.runCommand "watchdog-witness-check" { } ''
  ${run}
  touch $out
''
