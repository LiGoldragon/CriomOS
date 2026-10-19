# Policy is selected from Horizon's projected hardware model, never node names.
{
  lib,
  pkgs,
  model,
}:
let
  policies = {
    ThinkPadT14Gen2Intel = {
      acpi = [
        "GLAN"
        "TXHC"
        "TDM0"
        "TDM1"
        "TRP0"
        "TRP2"
      ];
      pci = [ ];
      ethernet = [ ];
      runtimePmOn = [ ];
    };
    # 8086:550b runtime autosuspend can storm GPE 6D and leave ULP unusable.
    # Keep runtime PM on for this NIC; system-suspend callbacks still run.
    # https://lists.openwall.net/linux-kernel/2024/08/19/167
    # Meteor Lake: Ethernet and USB wake share GPE 6D. Disable the devices'
    # wake requests, not the shared interrupt or unrelated wake sources.
    ThinkPadT14Gen5Intel = {
      acpi = [
        "GLAN"
        "XHCI"
      ];
      pci = [
        "0000:00:1f.6"
        "0000:00:14.0"
      ];
      ethernet = [ "0000:00:1f.6" ];
      runtimePmOn = [
        {
          pci = "0000:00:1f.6";
          vendor = "0x8086";
          device = "0x550b";
        }
      ];
    };
  };
  policy =
    policies.${model} or {
      acpi = [ ];
      pci = [ ];
      ethernet = [ ];
      runtimePmOn = [ ];
    };
  words = xs: lib.escapeShellArgs xs;
in
{
  inherit policy;
  enabled = policy.acpi != [ ];
  script = pkgs.writeShellScript "disable-model-spurious-wakeups" ''
    set -euo pipefail
    # An alternate filesystem root is only used by the sandbox regression.
    root="''${1:-}"
    test -r "$root/proc/acpi/wakeup"
    for device in ${words policy.pci}; do
      test -w "$root/sys/bus/pci/devices/$device/power/wakeup"
    done
    for device in ${words policy.ethernet}; do
      test -d "$root/sys/bus/pci/devices/$device/net"
      test -w "$root/sys/bus/pci/devices/$device/power/control"
    done
    ${lib.concatMapStringsSep "\n" (device: ''
      device="$root/sys/bus/pci/devices/${device.pci}"
      vendor=$(cat "$device/vendor")
      device_id=$(cat "$device/device")
      if test "$vendor" = ${lib.escapeShellArg device.vendor} &&
         test "$device_id" = ${lib.escapeShellArg device.device}; then
        printf '%s\n' on > "$device/power/control"
      fi
    '') policy.runtimePmOn}
    for device in ${words policy.ethernet}; do
      found=0
      for net in "$root/sys/bus/pci/devices/$device/net/"*; do
        test -e "$net" || continue
        found=1
        ${pkgs.ethtool}/bin/ethtool -s "''${net##*/}" wol d
      done
      test "$found" = 1
    done
    for device in ${words policy.pci}; do
      wake="$root/sys/bus/pci/devices/$device/power/wakeup"
      if test -e "$wake"; then
        printf '%s\n' disabled > "$wake"
      fi
    done
    for source in ${words policy.acpi}; do
      if ${pkgs.gawk}/bin/awk -v source="$source" '$1 == source && $3 == "*enabled" { found = 1 } END { exit !found }' "$root/proc/acpi/wakeup"; then
        printf '%s\n' "$source" > "$root/proc/acpi/wakeup"
      else
        status=$?
        test "$status" = 1 || exit "$status"
      fi
    done
  '';
}
