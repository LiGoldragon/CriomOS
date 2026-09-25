#!/usr/bin/env bash
set -euo pipefail

# A generation switch can install this match after an adapter was already
# enumerated. Reloading alone does not revisit that link, so target only the
# links owned by the router's USB-downlink rule.
wan_interface="$1"
networkctl reload

for link_path in "${SYS_CLASS_NET:-/sys/class/net}"/*; do
  interface="$(basename "$link_path")"
  if [ "$interface" != "$wan_interface" ] \
    && udevadm info --query=property --path="$link_path" | grep -qx 'ID_BUS=usb'; then
    networkctl reconfigure "$interface"
  fi
done
