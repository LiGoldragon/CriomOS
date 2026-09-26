# Tailnet membership, declared end to end: tailscaled runs, and a oneshot
# enrolls the node with the cluster's Headscale using this node's own
# reusable preauth key. The login server is the TailnetController's domain
# from cluster data; the key reaches `tailscale` only as a file path
# (`--auth-key=file:`), never as an argument.
#
# The oneshot enrolls only a node whose backend reports NeedsLogin or
# NoState, so a healthy node is never re-registered. It passes `--reset` so
# the declared flags are the whole configuration, and `--force-reauth` so a
# node that remembers an older login server moves to the declared one.
{
  config,
  lib,
  pkgs,
  horizon,
  constants,
  inputs,
  ...
}:
let
  inherit (horizon) node;

  tailnet = import ./tailnet-roles.nix {
    inherit
      lib
      pkgs
      horizon
      constants
      ;
  };

  tailscale = lib.getExe' config.services.tailscale.package "tailscale";
  jq = lib.getExe pkgs.jq;
  preauthKeyPath = config.sops.secrets.${tailnet.preauthKeySecret}.path;

  enrollScript = ''
    set -euo pipefail

    backendState() {
      ${tailscale} status --json --peers=false | ${jq} -r '.BackendState'
    }

    # tailscaled reports NoState briefly while a remembered login resumes;
    # a node that stays in NoState has no working login.
    state=$(backendState)
    attempts=0
    while [ "$state" = NoState ] && [ "$attempts" -lt 30 ]; do
      sleep 1
      attempts=$((attempts + 1))
      state=$(backendState)
    done

    case "$state" in
      NeedsLogin | NoState) ;;
      *)
        echo "tailnet-enroll: backend state $state; already enrolled, not re-registering"
        exit 0
        ;;
    esac

    echo "tailnet-enroll: backend state $state; enrolling with ${tailnet.controlUrl}"
    exec ${tailscale} up \
      --reset \
      --force-reauth \
      --login-server=${tailnet.controlUrl} \
      --auth-key=file:${preauthKeyPath} \
      --hostname=${node.name} \
      --accept-dns=false \
      --timeout=90s
  '';
in
{
  config = lib.mkIf tailnet.isClient {
    sops.secrets.${tailnet.preauthKeySecret} = tailnet.sopsSecret inputs "TailnetClient" tailnet.preauthKeySecret {
      mode = "0400";
      restartUnits = [ "tailnet-enroll.service" ];
    };

    services.tailscale = {
      enable = true;
      openFirewall = true;
    };

    systemd.services.tailnet-enroll = {
      description = "Enroll this node in the cluster tailnet";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "tailscaled.service"
        "network-online.target"
      ]
      ++ lib.optional tailnet.isController "headscale.service";
      after = [
        "tailscaled.service"
        "network-online.target"
      ]
      ++ lib.optional tailnet.isController "headscale.service";
      # Retry until the control server answers; never give up.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "150s";
      };
      script = enrollScript;
    };
  };
}
