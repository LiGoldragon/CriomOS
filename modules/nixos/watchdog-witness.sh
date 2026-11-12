#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
identity_path=${CRIOMOS_WATCHDOG_IDENTITY_PATH:-/sys/class/watchdog/watchdog0/identity}
status_path=${CRIOMOS_WATCHDOG_BOOTSTATUS_PATH:-/sys/class/watchdog/watchdog0/bootstatus}

# Each sysfs attribute is read by exactly one cat.  In particular, bootstatus
# is the driver's saved initialization value and is read only after the exact
# SP5100 identity has been established.
if ! identity=$(cat "$identity_path" 2>/dev/null); then
  echo "watchdog witness failed: driver identity could not be read" >&2
  exit 1
fi
if [ -z "$identity" ]; then
  echo "watchdog witness failed: driver identity is empty" >&2
  exit 1
fi
if [ "$identity" != "SP5100 TCO timer" ]; then
  echo "watchdog witness skipped: driver identity is outside SP5100 scope; no SP5100 status was read" >&2
  exit 0
fi
if ! status=$(cat "$status_path" 2>/dev/null); then
  echo "watchdog witness failed: SP5100 saved bootstatus could not be read" >&2
  exit 1
fi
case "$status" in
  ''|*[!0-9]*)
    echo "watchdog witness failed: SP5100 saved bootstatus is malformed" >&2
    exit 1
    ;;
esac

# Normalize only for checked arithmetic.  The journal retains the exact valid
# decimal bytes read from sysfs, including leading zeroes.
numeric_status=$status
while [ "${numeric_status#0}" != "$numeric_status" ]; do
  numeric_status=${numeric_status#0}
done
[ -n "$numeric_status" ] || numeric_status=0

# bootstatus is a u32 in the watchdog UAPI.  Bound its decimal representation
# before any shell arithmetic so neither overflow nor octal syntax can wrap or
# produce a false watchdog classification.
if [ "${#numeric_status}" -gt 10 ] || { [ "${#numeric_status}" -eq 10 ] && [ "$numeric_status" -gt 4294967295 ]; }; then
  echo "watchdog witness failed: SP5100 saved bootstatus is outside u32" >&2
  exit 1
fi
if [ $((numeric_status & 32)) -ne 0 ]; then
  classification=watchdog-fired
else
  classification=unknown
fi

# systemd-cat stores this as one parseable MESSAGE.  The key/value tokens are
# deliberately lowercase message content, not claimed as native journal fields.
printf 'criomos_watchdog_witness driver_identity=sp5100_tco_timer raw_bootstatus=%s classification=%s\n' "$status" "$classification" |
  systemd-cat --priority=notice --identifier=criomos-watchdog-witness
