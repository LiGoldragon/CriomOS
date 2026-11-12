{
  config,
  horizon,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatMapStringsSep
    filter
    mkIf
    mkOption
    types
    unique
    ;
  cfg = config.criomos.harnessUpdate;
  lojix = config.services.lojix;

  # The harnesses are updated where Lojix runs: its owner holds the keys that
  # push and submit deployments, and every build goes to the cluster's
  # builder as any Lojix deployment does. The owner's Homes are the targets:
  # one on every node his key is on.
  owner = lib.findFirst (user: user.name == lojix.user) null horizon.users;
  allNodes = [ horizon.node ] ++ lib.attrValues (horizon.exNodes or { });
  domainOf =
    name:
    let
      entry = lib.findFirst (candidate: candidate.name == name) null allNodes;
    in
    if entry == null then null else entry.criomeDomainName;
  targetNodes =
    if owner == null then
      [ ]
    else
      filter (name: domainOf name != null) (unique (map (key: key.node) owner.publicKeys));
  targets = concatMapStringsSep " " (name: "${name}=${domainOf name}") targetNodes;

  update = pkgs.writeShellApplication {
    name = "harness-update";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.nix
      pkgs.openssh
      pkgs.python3
      lojix.ordinaryClientPackage
      lojix.metaClientPackage
    ];
    text = ''
      work="$STATE_DIRECTORY"
      report="$work/report"
      : > "$report"
      say() { printf '%s\n' "$*" | tee -a "$report"; }
      notify() {
        text="$(tr '\n' ' ' < "$report" | sed 's/«/"/g; s/»/"/g')"
        ${cfg.notifyCommand} "Send.{ ${cfg.notifyAddress} Soft.Notice.«Harness update: $text» }" || true
      }
      trap 'say "stopped at line $LINENO"; notify' ERR

      sync() {
        if [ -d "$work/$1/.git" ]; then
          git -C "$work/$1" fetch -q origin
          git -C "$work/$1" checkout -q -f -B ${cfg.branch} origin/main
          git -C "$work/$1" reset -q --hard origin/main
          git -C "$work/$1" clean -qfdx
        else
          git clone -q "$2" "$work/$1"
          git -C "$work/$1" checkout -q -B ${cfg.branch} origin/main
        fi
      }
      sync home ${lib.escapeShellArg cfg.homeRepository}
      sync system ${lib.escapeShellArg cfg.systemRepository}
      sync cluster ${lib.escapeShellArg cfg.clusterRepository}

      cd "$work/home"
      for harness in ${lib.concatStringsSep " " cfg.harnesses}; do
        python3 -I "owned-agents/$harness/update.py" --root . 2>&1 | tail -n 1 | tee -a "$report"
      done
      if git diff --quiet; then
        say "nothing new."
        notify
        exit 0
      fi
      git commit -q -am "Update the harnesses to their latest releases" -m "$(cat "$report")"
      git push -q -f origin ${cfg.branch}
      home="$(git rev-parse HEAD)"

      cd "$work/system"
      # The lock pins the Home commit on the update branch; main does not
      # hold it until the Realize below has succeeded.
      nix flake lock --override-input criomos-home "github:${cfg.homeFlake}/$home"
      git commit -q -am "Pin Home with the harnesses updated (CriomOS-home ''${home:0:8})"
      git push -q -f origin ${cfg.branch}
      system="$(git rev-parse HEAD)"

      proposal="$(nix build --no-link --print-out-paths "$work/cluster#horizon-definition")/horizon-definition.datom"

      # Each deployment is waited on by its event: a watch on the node is
      # opened first, the request submitted, and the watch read line by line
      # until this deployment's phase event carries its terminal.
      deploy() {
        coproc WATCH { exec lojix "WatchDeployments.{ None Some.${horizon.cluster} Some.$2 }"; }
        read -r opened <&"''${WATCH[0]}"
        case "$opened" in Watching.*) ;; *) say "$2 $1: the watch did not open ($opened)"; return 1 ;; esac
        request="Deploy.UserEnvironment.{ ${horizon.cluster} $2 ${lojix.user} $proposal SecretsDirectory.$work/cluster/secrets github:${cfg.systemFlake}?rev=$system { ssh-ng://${lojix.user}@$3 ${lojix.user}@$3 } Horizon { homeConfigurations.${lojix.user}.activationPackage } HomeManagerNixProfileV1 $1 RequireImmutable Some.@/etc/nix/machines [] }"
        identifier="$(lojix-meta "$request" | grep -oE 'DeployAccepted\.\{ [0-9]+' | grep -oE '[0-9]+$')" || {
          say "$2 $1 refused"
          kill "$WATCH_PID"
          return 1
        }
        outcome=""
        while read -r event <&"''${WATCH[0]}"; do
          case "$event" in
            "DeploymentPhaseObserved.{ $identifier "*Some.Succeeded*) outcome=succeeded; break ;;
            "DeploymentPhaseObserved.{ $identifier "*Some.Failed*) outcome=failed; break ;;
            "DeploymentPhaseObserved.{ $identifier "*Some.Rejected*) outcome=rejected; break ;;
          esac
        done
        kill "$WATCH_PID" 2>/dev/null || true
        say "$2 $1 $identifier ''${outcome:-ended without its terminal}"
        [ "$outcome" = succeeded ]
      }

      realized=""
      for target in ${targets}; do
        if deploy Realize "''${target%%=*}" "''${target#*=}"; then realized="$realized $target"; fi
      done
      if [ -z "$realized" ]; then
        say "no Home realized; mains left as they were, the work is on branch ${cfg.branch}."
        notify
        exit 1
      fi
      git -C "$work/home" push -q origin ${cfg.branch}:main
      git -C "$work/system" push -q origin ${cfg.branch}:main
      say "CriomOS-home ''${home:0:8} and CriomOS ''${system:0:8} are on main."
      for target in $realized; do
        deploy ActivateNow "''${target%%=*}" "''${target#*=}" || true
      done
      notify
    '';
  };
in
{
  options.criomos.harnessUpdate = {
    interval = mkOption {
      type = types.str;
      default = "weekly";
      description = "When the harnesses are updated, as a systemd calendar event.";
    };
    harnesses = mkOption {
      type = types.listOf types.str;
      default = [
        "claude-code"
        "codex"
        "chatgpt"
        "claude-desktop"
      ];
      description = "The owned agent packages of CriomOS-home whose updaters run.";
    };
    homeRepository = mkOption {
      type = types.str;
      default = "git@github.com:LiGoldragon/CriomOS-home.git";
      description = "The CriomOS-home repository the update is pushed to.";
    };
    systemRepository = mkOption {
      type = types.str;
      default = "git@github.com:LiGoldragon/CriomOS.git";
      description = "The CriomOS repository whose lock pins the updated Home.";
    };
    homeFlake = mkOption {
      type = types.str;
      default = "LiGoldragon/CriomOS-home";
      description = "The CriomOS-home flake the update branch's commit is pinned from, as a GitHub owner and repository.";
    };
    systemFlake = mkOption {
      type = types.str;
      default = "LiGoldragon/CriomOS";
      description = "The CriomOS flake Lojix deploys from, as a GitHub owner and repository.";
    };
    clusterRepository = mkOption {
      type = types.str;
      default = "git@github.com:LiGoldragon/${horizon.cluster}.git";
      description = "The cluster data repository: its horizon-definition is the proposal, its secrets the secrets.";
    };
    branch = mkOption {
      type = types.str;
      default = "harness-update";
      description = "The branch the update is built on before it reaches main.";
    };
    notifyCommand = mkOption {
      type = types.str;
      default = "${config.users.users.${lojix.user}.home}/.local/bin/flow-nexus";
      description = "The Flow client the result is sent with, given one Send datom: the flow-nexus wrapper Home provides, which follows every Flow version.";
    };
    notifyAddress = mkOption {
      type = types.str;
      default = "{ Psyche core Opus }";
      description = "The address the result is sent to.";
    };
  };

  config = mkIf (lojix.enable && owner != null) {
    systemd.timers.harness-update = {
      description = "Update the harnesses";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };
    systemd.services.harness-update = {
      description = "Update the harnesses, build them through Lojix and deploy them";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        LOJIX_ORDINARY_SOCKET = lojix.ordinarySocketPath;
        LOJIX_OWNER_SOCKET = lojix.ownerSocketPath;
        HOME = config.users.users.${lojix.user}.home;
      };
      path = [
        "/etc/profiles/per-user/${lojix.user}"
        "${config.users.users.${lojix.user}.home}/.nix-profile"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = lojix.user;
        Group = lojix.group;
        StateDirectory = "harness-update";
        ExecStart = pkgs.writeShellScript "harness-update-with-agent" ''
          export XDG_RUNTIME_DIR="/run/user/$(${pkgs.coreutils}/bin/id -u)"
          export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gnupg/S.gpg-agent.ssh"
          exec ${update}/bin/harness-update
        '';
      };
    };
  };
}
