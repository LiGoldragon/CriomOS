{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  horizonNode = import ../../fixtures/horizon-node.nix { inherit lib; };
  configFor =
    model:
    (lib.nixosSystem {
      inherit pkgs;
      specialArgs = {
        inherit inputs;
        horizon.node = horizonNode.node {
          machine.hardware.model = model;
        };
      };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;
  gen5 = configFor "ThinkPadT14Gen5Intel";
  generic = configFor "all-x86-64";
  gen2 = import ../../modules/nixos/metal/suspend-wake-policy.nix {
    inherit lib pkgs;
    model = "ThinkPadT14Gen2Intel";
  };
  fakeEthtool = pkgs.writeShellScriptBin "ethtool" ''
    printf '%s\n' "$*" >> "$TEST_LOG"
    test "''${REFUSE_WOL:-0}" = 0
  '';
  policy = import ../../modules/nixos/metal/suspend-wake-policy.nix {
    inherit lib;
    pkgs = pkgs // {
      ethtool = fakeEthtool;
    };
    model = "ThinkPadT14Gen5Intel";
  };
in
assert gen5.systemd.services.disable-spurious-wakeups.before == [ "sleep.target" ];
assert gen5.systemd.services.disable-spurious-wakeups.requiredBy == [ "sleep.target" ];
assert !(generic.systemd.services ? disable-spurious-wakeups);
assert
  gen2.policy.acpi == [
    "GLAN"
    "TXHC"
    "TDM0"
    "TDM1"
    "TRP0"
    "TRP2"
  ];
assert
  policy.policy.acpi == [
    "GLAN"
    "XHCI"
  ];
assert !lib.hasInfix "gpe6D" (builtins.readFile policy.script);
pkgs.runCommand "metal-suspend-policy" { } ''
  export TEST_LOG="$PWD/ethtool.log"
  root="$PWD/fixture"
  mkdir -p "$root/proc/acpi"
  for device in 0000:00:1f.6 0000:00:14.0; do
    mkdir -p "$root/sys/bus/pci/devices/$device/power"
    echo enabled > "$root/sys/bus/pci/devices/$device/power/wakeup"
  done
  mkdir -p "$root/sys/bus/pci/devices/0000:00:1f.6/net/renamed-ethernet"
  printf 'GLAN S4 *disabled pci:0000:00:1f.6\nXHCI S3 *disabled pci:0000:00:14.0\n' > "$root/proc/acpi/wakeup"
  cp "$root/proc/acpi/wakeup" expected-disabled
  ${policy.script} "$root"
  cmp "$root/proc/acpi/wakeup" expected-disabled
  grep -qx -- '-s renamed-ethernet wol d' "$TEST_LOG"
  for device in 0000:00:1f.6 0000:00:14.0; do
    grep -qx disabled "$root/sys/bus/pci/devices/$device/power/wakeup"
  done
  ${policy.script} "$root"
  cmp "$root/proc/acpi/wakeup" expected-disabled
  for source in GLAN XHCI; do
    printf '%s S4 *enabled pci:fixture\n' "$source" > "$root/proc/acpi/wakeup"
    ${policy.script} "$root"
    test "$(cat "$root/proc/acpi/wakeup")" = "$source"
  done
  echo 'GLAN S4 *disabled pci:fixture' > "$root/proc/acpi/wakeup"
  echo enabled > "$root/sys/bus/pci/devices/0000:00:1f.6/power/wakeup"
  if REFUSE_WOL=1 ${policy.script} "$root"; then
    echo 'Wake-on-LAN refusal was ignored' >&2; exit 1
  fi
  grep -qx enabled "$root/sys/bus/pci/devices/0000:00:1f.6/power/wakeup"
  rm "$root/sys/bus/pci/devices/0000:00:1f.6/power/wakeup"
  if ${policy.script} "$root"; then
    echo 'Missing model wake control was ignored' >&2; exit 1
  fi
  touch "$out"
''
