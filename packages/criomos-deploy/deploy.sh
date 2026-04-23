#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: criomos-deploy <cluster> <node> [--boot] [--commit <hash>] [--via <builder>]"
  echo ""
  echo "Build fullOs, set system profile, and activate on <node>."
  echo ""
  echo "  --boot          Set boot entry only, don't activate (for kernel changes)"
  echo "  --commit        Build specific commit (default: current main)"
  echo "  --via <builder> Build on <builder> and copy closure to <node>."
  echo "                  <builder> can be 'local' (this machine) or an SSH host."
  echo "                  Useful when <node> has a slow connection or weak CPU."
  echo ""
  echo "Examples:"
  echo "  criomos-deploy maisiliym zeus"
  echo "  criomos-deploy maisiliym zeus --boot"
  echo "  criomos-deploy maisiliym prometheus --commit abc123"
  echo "  criomos-deploy maisiliym zeus --via local"
  echo "  criomos-deploy maisiliym zeus --via ouranos.maisiliym.criome"
  exit 1
}

[ $# -lt 2 ] && usage

CLUSTER="$1"; shift
NODE="$1"; shift

[[ "$CLUSTER" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid cluster: ${CLUSTER}"; exit 1; }
[[ "$NODE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid node: ${NODE}"; exit 1; }

MODE="switch"
COMMIT=""
VIA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --boot)   MODE="boot"; shift ;;
    --commit)
      [ $# -lt 2 ] && { echo "Error: --commit requires an argument"; exit 1; }
      COMMIT="$2"; shift 2
      ;;
    --via)
      [ $# -lt 2 ] && { echo "Error: --via requires an argument"; exit 1; }
      VIA="$2"; shift 2
      ;;
    *)        usage ;;
  esac
done

REPO="github:LiGoldragon/CriomOS"

if [ -z "$COMMIT" ]; then
  COMMIT=$(jj log -r main -T 'commit_id' --no-graph 2>/dev/null) || true
  [ -z "$COMMIT" ] && { echo "Error: failed to get commit hash from jj"; exit 1; }
fi

REF="${REPO}/${COMMIT}"
ATTR="${REF}#crioZones.${CLUSTER}.${NODE}.fullOs"
HOST="${NODE}.${CLUSTER}.criome"

if [ -z "$VIA" ]; then
  echo "Deploying ${CLUSTER}/${NODE} from ${COMMIT:0:12} (${MODE}) — build on target..."
  ssh root@"${HOST}" \
    "rm -f /tmp/criomos-deploy \
     && nix build '${ATTR}' --no-write-lock-file -o /tmp/criomos-deploy \
     && RESULT=\$(readlink /tmp/criomos-deploy) \
     && [ -n \"\$RESULT\" ] \
     && nix-env -p /nix/var/nix/profiles/system --set \"\$RESULT\" \
     && \"\$RESULT\"/bin/switch-to-configuration ${MODE}"
else
  echo "Deploying ${CLUSTER}/${NODE} from ${COMMIT:0:12} (${MODE}) — build on ${VIA}, copy to target..."
  if [ "$VIA" = "local" ]; then
    RESULT=$(nix build "${ATTR}" --no-write-lock-file --no-link --print-out-paths)
  else
    RESULT=$(ssh root@"${VIA}" "nix build '${ATTR}' --no-write-lock-file --no-link --print-out-paths")
  fi
  [ -n "$RESULT" ] || { echo "Error: build produced no output path"; exit 1; }
  if [ "$VIA" = "local" ]; then
    nix copy --to "ssh://root@${HOST}" "$RESULT"
  else
    ssh root@"${VIA}" "nix copy --to 'ssh://root@${HOST}' '${RESULT}'"
  fi
  ssh root@"${HOST}" \
    "nix-env -p /nix/var/nix/profiles/system --set '${RESULT}' \
     && '${RESULT}/bin/switch-to-configuration' ${MODE}"
fi

echo "Done: ${CLUSTER}/${NODE} ${MODE}"
