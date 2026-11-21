{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;
  cfg = config.criomos.gitPublication;
  protocol = ./git-publication/delivery.py;
  senderName = "git-publication-wake";
  receiverName = "git-publication-receiver";
  receiverWakeDirectory = "/run/git-publication-reconnect";
  receiverWake = "${receiverWakeDirectory}/ready";
  wakeDirectory = "/var/lib/git-publication-wake";
  outbox = "/var/lib/git-publication-outbox";
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
    network = {
      peerAddress = mkOption {
        type = types.strMatching "[0-9a-fA-F:.]+";
        description = "Numeric peer address whose local route the observer watches.";
      };
      links = mkOption {
        type = types.listOf (types.strMatching "[a-zA-Z0-9_.:-]+");
        default = [];
        description = "Local links whose return calls for replay while the peer route is usable.";
      };
    };
    reconnectTargets = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+[.]target");
      default = [];
      description = "Targets started by the configured network owner on an additional return event.";
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
  receive = commandFor (configuration "receive" {
    inherit (cfg) repositories;
    inherit (cfg.receiver) curriculumEndpoint admissionTimeout;
  }) "receive";
  reconnect = commandFor (configuration "receiver" {
    wake = receiverWake;
    inherit (cfg.receiver) timeout;
    peerCommand = peer senderName cfg.receiver;
  }) "reconnect";
  receiverKick = commandFor (configuration "ready" { wake = receiverWake; }) "wake";
  watchNetwork = role: marker: endpoint: user:
    let
      settings = configuration "${role}-network" {
        wake = marker;
        inherit (endpoint) network;
        ip = "${pkgs.iproute2}/bin/ip";
      };
    in {
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        User = user;
        ExecStart = "${pkgs.python3}/bin/python3 -B ${./git-publication}/network.py ${settings}";
      };
    };
  listenForReturn = endpoint: command: user: {
    wantedBy = endpoint.reconnectTargets;
    partOf = endpoint.reconnectTargets;
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      ExecStart = command;
    };
  };
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
      readinessMarker = mkOption {
        type = types.str;
        default = receiverWake;
        readOnly = true;
        description = "Marker that the configured Curriculum listener announces after binding.";
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
      systemd.services.git-publication-sender-network = watchNetwork "sender" wake cfg.sender "git";
      systemd.services.git-publication-sender-return = listenForReturn cfg.sender kick "git";
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
      assertions = [{
        assertion = builtins.elem (config.systemd.services.sshd.serviceConfig.Type or "") [
          "notify" "notify-reload"
        ];
        message = "Git publication expects the OpenSSH readiness notification before its post-start wake.";
      }];
      users.groups.${receiverName} = {};
      users.users.${receiverName} = {
        isSystemUser = true;
        group = receiverName;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = authenticated receive cfg.receiver.authorizedKeys;
      };
      systemd.tmpfiles.rules = [ "d ${receiverWakeDirectory} 0770 ${receiverName} ${receiverName} -" ];
      systemd.services.git-publication-receiver-network =
        watchNetwork "receiver" receiverWake cfg.receiver receiverName;
      systemd.services.git-publication-receiver-return =
        listenForReturn cfg.receiver receiverKick receiverName;
      systemd.services.sshd.postStart = lib.mkAfter ''${receiverKick} </dev/null'';
      systemd.paths.git-publication-reconnect = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathExists = receiverWake;
      };
      systemd.services.git-publication-reconnect = {
        after = [ "sshd.service" "systemd-tmpfiles-setup.service" ];
        serviceConfig = credentials cfg.receiver // {
          Type = "oneshot";
          User = receiverName;
          ExecStart = reconnect;
        };
      };
    })
  ];
}
