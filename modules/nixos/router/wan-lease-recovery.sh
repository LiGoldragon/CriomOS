set -euo pipefail

wan=$1

# No cable means no upstream DHCP server to ask. Preserve the current link.
if ! ip -o link show dev "$wan" | grep -q 'LOWER_UP'; then
  exit 0
fi

# A working DHCP default route must never be disturbed by this timer.
if ip -4 route show default dev "$wan" | grep -q '^default '; then
  exit 0
fi

echo "router WAN $wan has carrier but no IPv4 default route; reconfiguring only that link" >&2
networkctl reconfigure "$wan"
