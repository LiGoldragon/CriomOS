set -eu
script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pci=0000:c7:00.0

make_device() {
  path=$work/$1
  mkdir -p "$path/power"
  printf '%s\n' "$2" > "$path/devpath"
  printf '%s\n' "$3" > "$path/idVendor"
  printf '%s\n' "$4" > "$path/idProduct"
  printf '%s\n' "$5" > "$path/bcdDevice"
  printf '%s\n' "$6" > "$path/serial"
  printf '%s\n' auto > "$path/power/control"
}

run() {
  bash "$script" "$work" declared-router "$1" "$pci" 2 0b95 1790 0200 unit-123
}
assert_policy() {
  test "$(cat "$work/$1/power/control")" = "$2"
}

target=$pci/usb7/7-2
control=$pci/usb7/7-1
other_pci=0000:c7:00.1/usb8/8-2
other_serial=$pci/usb9/9-2
other_revision=$pci/usb10/10-2
make_device "$target" 2 0b95 1790 0200 unit-123
make_device "$control" 1 0b95 1790 0100 protected-control
make_device "$other_pci" 2 0b95 1790 0200 unit-123
make_device "$other_serial" 2 0b95 1790 0200 other
make_device "$other_revision" 2 0b95 1790 0100 unit-123

if run wrong-router; then exit 1; fi
assert_policy "$target" auto
run declared-router
run declared-router
assert_policy "$target" on
for untouched in "$control" "$other_pci" "$other_serial" "$other_revision"; do
  assert_policy "$untouched" auto
done

# A second exact identity is an ambiguity, not permission to write either.
printf '%s\n' auto > "$work/$target/power/control"
duplicate=$pci/usb11/11-2
make_device "$duplicate" 2 0b95 1790 0200 unit-123
if run declared-router; then exit 1; fi
assert_policy "$target" auto
assert_policy "$duplicate" auto

# A stable physical port must continue working after kernel bus renumbering.
rm -rf "$work/$target"
run declared-router
assert_policy "$duplicate" on

# With no exact adapter present, wait for actual enumeration rather than reset.
rm -rf "$work/$duplicate"
run declared-router
assert_policy "$control" auto
