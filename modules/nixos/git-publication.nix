{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;
  cfg = config.criomos.gitPublication;
  protocol = ./git-publication/delivery.py;
  senderName = "git-publication-wake";
  receiverName = "git-publication-receiver";
  wakeDirectory = "/var/lib/git-publication-wake";
  outbox = "/var/lib/git-publication-outbox";
  inbox = "/var/lib/git-publication-inbox";
  wake = "${wakeDirectory}/ready";
  sshOptions = {
    peer = mkOption {
      type = types.strMatching "[a-zA-Z0-9.:-]+";
      description = "SSH hostname of the other publication route endpoint.";
    };
    port = mkOption {
      type = types.port;
      default = 22;
      description = "SSH service port of the other publication route endpoint.";
    };
    knownHosts = mkOption {
      type = types.path;
      description = "Known-hosts file pinning the publication peer.";
    };
    identityFile = mkOption {
      type = types.str;
      description = "Absolute credential path loaded by systemd for outbound publication SSH.";
    };
    authorizedKeys = mkOption {
      type = types.nonEmptyListOf (types.strMatching "ssh-ed25519 [a-zA-Z0-9+/=]+");
      description = "Peer public keys authorized for this role's single forced command.";
    };
    timeout = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Maximum seconds to wait for the peer's acknowledgement.";
    };
  };
  peer = user: endpoint: [
    "${pkgs.openssh}/bin/ssh"
    "-F" "/dev/null"
    "-o" "BatchMode=yes"
    "-o" "StrictHostKeyChecking=yes"
    "-o" "UserKnownHostsFile=${endpoint.knownHosts}"
    "-o" "GlobalKnownHostsFile=/dev/null"
    "-o" "IdentitiesOnly=yes"
    "-i" "$CREDENTIALS_DIRECTORY/publication-key"
    "-T" "-p" (toString endpoint.port)
    "-l" user
    endpoint.peer
  ];
  commandFor = path: operation: pkgs.writeShellScript "git-publication-${operation}" ''
    exec ${pkgs.python3}/bin/python3 ${protocol} ${path} ${operation} "$@"
  '';
  authenticated = command: map (key: ''restrict,command="${command}" ${key}'');
  configuration = name: value: pkgs.writeText "git-publication-${name}.json" (builtins.toJSON value);
  enqueue = commandFor (configuration "outbox" {
    inherit (cfg) repositories;
    inherit outbox wake;
  }) "enqueue";
  drain = commandFor (configuration "sender" {
    inherit (cfg) repositories;
    inherit (cfg.sender) timeout;
    inherit outbox wake;
    peerCommand = peer receiverName cfg.sender;
  }) "deliver";
  kick = commandFor (configuration "wake" { inherit wake; }) "wake";
  receive = commandFor (configuration "inbox" {
    inherit (cfg) repositories;
    inherit inbox;
    inherit (cfg.receiver) curriculumEndpoint admissionTimeout;
  }) "receive";
  reconnect = commandFor (configuration "receiver" {
    inherit (cfg.receiver) timeout;
    peerCommand = peer senderName cfg.receiver;
  }) "reconnect";
  credentials = endpoint: {
    LoadCredential = "publication-key:${endpoint.identityFile}";
  };

in
{
  options.criomos.gitPublication = {
    repositories = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+");
      default = [];
      description = "Authenticated Git repositories whose accepted main updates ride this route.";
    };
    enqueueCommand = mkOption {
      type = types.nullOr types.path;
      default = null;
      internal = true;
      description = "Sender command invoked by the primary Git post-receive hook.";
    };
    sender = sshOptions // { enable = mkEnableOption "the Git publication outbox and replay endpoint"; };
    receiver = sshOptions // {
      enable = mkEnableOption "the Git publication receiver and reconnect signal";
      curriculumEndpoint = mkOption {
        type = types.strMatching "/.+";
        description = "Absolute socket path of the local Curriculum publication admission endpoint.";
      };
      admissionTimeout = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Maximum seconds to wait for Curriculum's local admission.";
      };
      reconnectTargets = mkOption {
        type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+[.]target");
        default = [];
        description = "Targets started by the deployment when the receiver can reach the sender again.";
      };
    };
  };

  config = mkMerge [
    (mkIf (cfg.sender.enable || cfg.receiver.enable) {
      assertions = [
        {
          assertion = cfg.repositories != [];
          message = "Git publication requires at least one configured repository.";
        }
        {
          assertion = config.services.openssh.enable;
          message = "Git publication endpoints need the host OpenSSH service.";
        }
      ];
    })
    (mkIf cfg.sender.enable {
      criomos.gitPublication.enqueueCommand = enqueue;
      users.groups.${senderName} = {};
      users.users.${senderName} = {
        isSystemUser = true;
        group = senderName;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = authenticated kick cfg.sender.authorizedKeys;
      };
      users.users.git.extraGroups = [ senderName ];
      systemd.tmpfiles.rules = [
        "d ${outbox} 0700 git git -"
        "d ${wakeDirectory} 2770 ${senderName} ${senderName} -"
      ];
      systemd.paths.git-publication-deliver = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathExists = wake;
      };
      systemd.services.git-publication-deliver = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
        serviceConfig = credentials cfg.sender // {
          Type = "oneshot";
          User = "git";
          SupplementaryGroups = [ senderName ];
          ExecStart = drain;
        };
      };
    })
    (mkIf cfg.receiver.enable {
      users.groups.${receiverName} = {};
      users.users.${receiverName} = {
        isSystemUser = true;
        group = receiverName;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = authenticated receive cfg.receiver.authorizedKeys;
      };
      systemd.tmpfiles.rules = [ "d ${inbox} 0700 ${receiverName} ${receiverName} -" ];
      systemd.services.git-publication-reconnect = {
        wantedBy = [ "multi-user.target" ] ++ cfg.receiver.reconnectTargets;
        wants = [ "network-online.target" ];
        after = [ "sshd.service" "network-online.target" "systemd-tmpfiles-setup.service" ];
        partOf = [ "sshd.service" ] ++ cfg.receiver.reconnectTargets;
        serviceConfig = credentials cfg.receiver // {
          Type = "oneshot";
          RemainAfterExit = true;
          User = receiverName;
          ExecStart = reconnect;
        };
      };
    })
  ];
}
