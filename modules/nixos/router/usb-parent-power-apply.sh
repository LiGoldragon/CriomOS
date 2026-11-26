# Args: sysfs PCI devices directory, expected hostname, current hostname, controller,
# root port, vendor, product, revision, serial.
set -eu
root=$1
expected_host=$2
current_host=$3
controller=$4
port=$5
vendor=$6
product=$7
revision=$8
serial=$9

if [ "$current_host" != "$expected_host" ]; then
  printf '%s\n' "USB parent power: wrong host; no change" >&2
  exit 1
fi

matches_identity() {
  directory=$1
  for key in devpath idVendor idProduct bcdDevice serial; do
    case "$key" in
      devpath) expected=$port ;;
      idVendor) expected=$vendor ;;
      idProduct) expected=$product ;;
      bcdDevice) expected=$revision ;;
      serial) expected=$serial ;;
    esac
    value=
    if ! IFS= read -r value < "$directory/$key" || [ "$value" != "$expected" ]; then
      return 1
    fi
  done
}

shopt -s nullglob
matched=
for candidate in "$root/$controller"/usb[0-9]*/[0-9]*-"$port"; do
  [ -d "$candidate" ] && ! [ -L "$candidate" ] || continue
  parent=${candidate%/*}
  bus=${parent##*/usb}
  case "$bus" in
    ''|*[!0-9]*) continue ;;
  esac
  [ "${candidate##*/}" = "$bus-$port" ] || continue
  if matches_identity "$candidate"; then
    if [ -n "$matched" ]; then
      printf '%s\n' "USB parent power: ambiguous device identity; no change" >&2
      exit 1
    fi
    matched=$candidate
  fi
done

if [ -z "$matched" ]; then
  printf '%s\n' "USB parent power: declared device absent; waiting for normal enumeration"
  exit 0
fi

# Hold the directory open and revalidate it, so a new instance at this path
# cannot receive the write after the original disappears.
exec 9< "$matched"
parent=/proc/self/fd/9
if ! matches_identity "$parent"; then
  printf '%s\n' "USB parent power: device changed before application" >&2
  exit 1
fi
policy=
IFS= read -r policy < "$parent/power/control"
if [ "$policy" != on ]; then
  printf 'on\n' > "$parent/power/control"
fi
IFS= read -r policy < "$parent/power/control"
[ "$policy" = on ]
printf '%s\n' "USB parent power: verified on for the declared device"
