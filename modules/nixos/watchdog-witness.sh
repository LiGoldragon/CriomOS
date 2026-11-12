#!/bin/sh
set -eu
identity_path=${CRIOMOS_WATCHDOG_IDENTITY_PATH:-/sys/class/watchdog/watchdog0/identity}
status_path=${CRIOMOS_WATCHDOG_BOOTSTATUS_PATH:-/sys/class/watchdog/watchdog0/bootstatus}
identity=$(cat "$identity_path" 2>/dev/null || true)
status=$(cat "$status_path" 2>/dev/null || true)
if [ "$identity" != "SP5100 TCO timer" ]; then
  echo "watchdog witness: driver identity '${identity}' is outside SP5100 witness scope" >&2
  exit 0
fi
case "$status" in
  ''|*[!0-9]*)
    echo "watchdog witness: malformed bootstatus '${status}'" >&2
    exit 1
    ;;
esac
# bootstatus is a u32 in the watchdog UAPI; reject overflow rather than
# allowing shell arithmetic to wrap and produce a false classification.
if [ "$status" -gt 4294967295 ] 2>/dev/null; then
  echo "watchdog witness: bootstatus overflows u32 '${status}'" >&2
  exit 1
fi
# Preserve the driver's raw decimal value while classifying only its documented bit.
if [ $((status & 32)) -ne 0 ]; then
  classification=watchdog-fired
else
  classification=unknown/inconclusive
fi
printf 'MESSAGE=criomos watchdog witness DRIVER_IDENTITY=%s RAW_BOOTSTATUS=%s CLASSIFICATION=%s\n' "$identity" "$status" "$classification" |
  systemd-cat --priority=notice --identifier=criomos-watchdog-witness
