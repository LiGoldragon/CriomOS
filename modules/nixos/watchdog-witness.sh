#!/bin/sh
set -eu
identity_path=${CRIOMOS_WATCHDOG_IDENTITY_PATH:-/sys/class/watchdog/watchdog0/identity}
status_path=${CRIOMOS_WATCHDOG_BOOTSTATUS_PATH:-/sys/class/watchdog/watchdog0/bootstatus}
identity=$(cat "$identity_path" 2>/dev/null || true)
status=$(cat "$status_path" 2>/dev/null || true)
if [ "$identity" != "SP5100 TCO timer" ]; then
  echo "watchdog witness: expected SP5100 TCO timer identity, got '${identity}'" >&2
  exit 1
fi
case "$status" in
  ''|*[!0-9]*)
    echo "watchdog witness: malformed bootstatus '${status}'" >&2
    exit 1
    ;;
esac
# Preserve the driver's raw decimal value while classifying only its documented bit.
if [ $((status & 32)) -ne 0 ]; then
  classification=watchdog-fired
else
  classification=unknown/inconclusive
fi
printf 'MESSAGE=criomos watchdog witness DRIVER_IDENTITY=%s RAW_BOOTSTATUS=%s CLASSIFICATION=%s\n' "$identity" "$status" "$classification" |
  systemd-cat --priority=notice --identifier=criomos-watchdog-witness
