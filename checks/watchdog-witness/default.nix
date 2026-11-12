{ pkgs, lib, ... }:
let
  script = ../../modules/nixos/watchdog-witness.sh;
  node = (import ../../fixtures/horizon-node.nix { inherit lib; }).node;
  makeSystem = router: lib.nixosSystem {
    inherit pkgs;
    specialArgs = {
      horizon.node = node {
        capabilities = [ ];
        behavesAs.router = router;
      };
    };
    modules = [ ../../modules/nixos/watchdog-witness.nix ];
  };
  routerSystem = makeSystem true;
  nonRouterSystem = makeSystem false;
  service = routerSystem.config.systemd.services.criomos-watchdog-witness;
  run = pkgs.writeShellScript "watchdog-witness-fixture-check" ''
    set -eu
    fixture=$(mktemp -d)
    trap 'rm -rf "$fixture"' EXIT
    fakebin="$fixture/bin"
    mkdir -p "$fakebin"

    cat > "$fakebin/systemd-cat" <<'CAT'
#!/bin/sh
${pkgs.coreutils}/bin/cat
CAT
    cat > "$fakebin/cat" <<'CAT'
#!/bin/sh
name=$(${pkgs.coreutils}/bin/basename "$1")
case "$name" in
  identity|bootstatus)
    count="$CRIOMOS_READ_COUNTS/$name"
    old=0
    test ! -e "$count" || old=$(${pkgs.coreutils}/bin/cat "$count")
    printf '%s\n' "$((old + 1))" > "$count"
    ;;
esac
exec ${pkgs.coreutils}/bin/cat "$@"
CAT
    chmod +x "$fakebin/systemd-cat" "$fakebin/cat"

    run_case() {
      name=$1 identity=$2 status=$3 expected=$4 classification=$5
      d="$fixture/$name"
      mkdir -p "$d/counts"
      printf '%s\n' "$identity" > "$d/identity"
      printf '%s\n' "$status" > "$d/bootstatus"
      if PATH="$fakebin" CRIOMOS_READ_COUNTS="$d/counts" \
        CRIOMOS_WATCHDOG_IDENTITY_PATH="$d/identity" \
        CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$d/bootstatus" \
        ${pkgs.bash}/bin/bash ${script} >"$d/out" 2>"$d/err"; then
        result=success
      else
        result=failure
      fi
      test "$result" = "$expected"
      test "$(${pkgs.coreutils}/bin/cat "$d/counts/identity")" = 1
      test "$(${pkgs.coreutils}/bin/cat "$d/counts/bootstatus")" = 1
      if test "$expected" = success; then
        grep -F "raw_bootstatus=$status" "$d/out" >/dev/null
        grep -F "classification=$classification" "$d/out" >/dev/null
      else
        test ! -s "$d/out"
      fi
    }

    run_case zero 'SP5100 TCO timer' 0 success unknown
    run_case fired 'SP5100 TCO timer' 32 success watchdog-fired
    run_case combined-bits 'SP5100 TCO timer' 96 success watchdog-fired
    run_case max-u32 'SP5100 TCO timer' 4294967295 success watchdog-fired
    run_case leading-zero 'SP5100 TCO timer' 00032 success watchdog-fired
    run_case empty-status 'SP5100 TCO timer' '' failure unused
    run_case malformed-hex 'SP5100 TCO timer' 0x20 failure unused
    run_case overflow 'SP5100 TCO timer' 999999999999999999999999 failure unused

    missing_identity="$fixture/missing-identity"
    mkdir -p "$missing_identity/counts"
    if PATH="$fakebin" CRIOMOS_READ_COUNTS="$missing_identity/counts" \
      CRIOMOS_WATCHDOG_IDENTITY_PATH="$missing_identity/identity" \
      CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$missing_identity/bootstatus" \
      ${pkgs.bash}/bin/bash ${script} >"$missing_identity/out" 2>"$missing_identity/err"; then
      exit 1
    fi
    grep -F 'identity could not be read' "$missing_identity/err" >/dev/null
    test ! -e "$missing_identity/counts/bootstatus"

    missing_status="$fixture/missing-status"
    mkdir -p "$missing_status/counts"
    printf 'SP5100 TCO timer\n' > "$missing_status/identity"
    if PATH="$fakebin" CRIOMOS_READ_COUNTS="$missing_status/counts" \
      CRIOMOS_WATCHDOG_IDENTITY_PATH="$missing_status/identity" \
      CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$missing_status/bootstatus" \
      ${pkgs.bash}/bin/bash ${script} >"$missing_status/out" 2>"$missing_status/err"; then
      exit 1
    fi
    grep -F 'bootstatus could not be read' "$missing_status/err" >/dev/null
    test ! -s "$missing_status/out"

    other="$fixture/unexpected-driver"
    mkdir -p "$other/counts"
    printf 'Other watchdog\n' > "$other/identity"
    PATH="$fakebin" CRIOMOS_READ_COUNTS="$other/counts" \
      CRIOMOS_WATCHDOG_IDENTITY_PATH="$other/identity" \
      CRIOMOS_WATCHDOG_BOOTSTATUS_PATH="$other/absent-status" \
      ${pkgs.bash}/bin/bash ${script} >"$other/out" 2>"$other/err"
    test ! -s "$other/out"
    test ! -e "$other/counts/bootstatus"
    grep -F 'no SP5100 status was read' "$other/err" >/dev/null
  '';
in
assert lib.assertMsg (service.wantedBy == [ "dev-watchdog0.device" ]) "witness has one static device-event activation";
assert lib.assertMsg (service.after == [ "dev-watchdog0.device" ]) "witness reads after the device event";
assert lib.assertMsg (service.bindsTo == [ "dev-watchdog0.device" ]) "witness is bound to the device lifecycle";
assert lib.assertMsg service.serviceConfig.RemainAfterExit "witness remains complete instead of repeating during the boot";
assert lib.assertMsg (!service.restartIfChanged) "configuration activation does not repeat the boot read";
assert lib.assertMsg (!service.stopIfChanged) "configuration activation preserves the completed boot read";
assert lib.assertMsg (service.path == [ pkgs.coreutils pkgs.systemd ]) "the runtime closure supplies cat and systemd-cat";
assert lib.assertMsg (!(nonRouterSystem.config.systemd.services ? criomos-watchdog-witness)) "non-router nodes have no witness unit";
pkgs.runCommand "watchdog-witness-check" { } ''
  ${run}
  touch $out
''
