#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: criomos-reload-shell [<cluster> <node>] <user>"
  echo ""
  echo "Restart noctalia-shell in a user's Wayland session."
  echo "With one arg, runs locally for that user."
  echo "With three args, runs remotely via SSH."
  echo ""
  echo "Examples:"
  echo "  criomos-reload-shell goldragon zeus bird"
  echo "  criomos-reload-shell li"
  exit 1
}

[ $# -lt 1 ] && usage

if [ $# -ge 3 ]; then
  CLUSTER="$1"
  NODE="$2"
  TARGET_USER="$3"
  HOST="${NODE}.${CLUSTER}.criome"
  run() { ssh root@"${HOST}" "$@"; }
elif [ $# -eq 1 ]; then
  TARGET_USER="$1"
  run() { "$@"; }
else
  usage
fi

[[ "$TARGET_USER" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid username: ${TARGET_USER}"; exit 1; }

UID_NUM=$(run id -u "${TARGET_USER}") || { echo "User ${TARGET_USER} not found"; exit 1; }
[ -z "$UID_NUM" ] && { echo "Failed to get UID for ${TARGET_USER}"; exit 1; }
RUNTIME="/run/user/${UID_NUM}"

run kill "$(run pgrep -u "${TARGET_USER}" quickshell 2>/dev/null)" 2>/dev/null || true
sleep 1
run su - "${TARGET_USER}" -c "WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=${RUNTIME} noctalia-shell &"

echo "Reloaded ${TARGET_USER}'s shell"
