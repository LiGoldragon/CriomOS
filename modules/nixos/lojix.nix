{ config, lib, pkgs, inputs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption optionalAttrs types;
  cfg = config.services.lojix;
  defaultPackage = inputs.lojix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  isDotosAtom = value: builtins.match "^[A-Za-z0-9_./:@+?=&%,-]+$" value != null;
  managedDirectories = lib.unique [
    cfg.stateDirectoryPath
    (lib.dirOf cfg.ordinarySocketPath)
    (lib.dirOf cfg.ownerSocketPath)
    (lib.dirOf cfg.startupArchivePath)
  ];
  startupRequest = pkgs.writeText "lojix-daemon-configuration.dotos" ''
    (ConfigurationWriteRequest (${cfg.ordinarySocketPath} ${toString cfg.ordinarySocketMode} ${cfg.ownerSocketPath} ${toString cfg.ownerSocketMode} ${cfg.stateDirectoryPath} ${cfg.daemonHost} ${toString cfg.effectTimeoutSeconds} NoTestDefaults ${cfg.startupArchivePath}))
  '';
in
{
  options.services.lojix = {
    enable = mkEnableOption "the Lojix deployment daemon";

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      description = "The versioned Lojix package providing the daemon, clients, writer, and reset primitive.";
    };

    user = mkOption {
      type = types.str;
      description = "Existing unprivileged account that owns the Lojix daemon and store.";
    };

    group = mkOption {
      type = types.str;
      description = "Existing group used by the Lojix daemon and owner socket.";
    };

    ordinarySocketPath = mkOption {
      type = types.str;
      description = "Absolute Unix-socket path exported to ordinary Lojix clients.";
    };

    ordinarySocketMode = mkOption {
      type = types.ints.between 0 511;
      default = 432;
      description = "Unix mode encoded for the ordinary socket.";
    };

    ownerSocketPath = mkOption {
      type = types.str;
      description = "Absolute Unix-socket path exported to owner/meta Lojix clients.";
    };

    ownerSocketMode = mkOption {
      type = types.ints.between 0 504;
      default = 384;
      description = "Unix mode encoded for the owner/meta socket; other access is forbidden by Lojix.";
    };

    stateDirectoryPath = mkOption {
      type = types.str;
      description = "Absolute directory holding the configured Lojix store and generated private inputs.";
    };

    storePath = mkOption {
      type = types.str;
      description = "Exact absolute Lojix store file. The reset unit accepts only a path named lojix.sema.";
    };

    startupArchivePath = mkOption {
      type = types.str;
      description = "Absolute generated rkyv daemon startup archive path.";
    };

    daemonHost = mkOption {
      type = types.str;
      description = "Explicit daemon host identity used only for self-switch safety.";
    };

    effectTimeoutSeconds = mkOption {
      type = types.ints.positive;
      description = "Maximum duration of one external Lojix Nix, SSH, or activation effect.";
    };

    sshAuthSocket = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional explicitly configured SSH agent socket supplied to the daemon.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "services.lojix.user must name an existing user";
      }
      {
        assertion = builtins.hasAttr cfg.group config.users.groups;
        message = "services.lojix.group must name an existing group";
      }
      {
        assertion = lib.hasPrefix "/" cfg.ordinarySocketPath
          && lib.hasPrefix "/" cfg.ownerSocketPath
          && lib.hasPrefix "/" cfg.stateDirectoryPath
          && lib.hasPrefix "/" cfg.storePath
          && lib.hasPrefix "/" cfg.startupArchivePath;
        message = "services.lojix socket, state, store, and startup paths must be absolute";
      }
      {
        assertion = builtins.baseNameOf cfg.storePath == "lojix.sema";
        message = "services.lojix.storePath must be the exact Lojix file name lojix.sema";
      }
      {
        assertion = cfg.storePath == "${cfg.stateDirectoryPath}/lojix.sema";
        message = "services.lojix.storePath must be the exact store the daemon opens under services.lojix.stateDirectoryPath";
      }
      {
        assertion = lib.all (directory: directory != "/") managedDirectories;
        message = "services.lojix managed state, socket, and startup directories must not be the filesystem root";
      }
      {
        assertion = lib.all isDotosAtom [
          cfg.ordinarySocketPath
          cfg.ownerSocketPath
          cfg.stateDirectoryPath
          cfg.storePath
          cfg.startupArchivePath
          cfg.daemonHost
        ] && (cfg.sshAuthSocket == null || isDotosAtom cfg.sshAuthSocket);
        message = "services.lojix paths and daemonHost must be nonempty DOTOS atoms without whitespace or control syntax";
      }
    ];

    environment.systemPackages = [ cfg.package ];
    environment.variables = {
      LOJIX_ORDINARY_SOCKET = cfg.ordinarySocketPath;
      LOJIX_OWNER_SOCKET = cfg.ownerSocketPath;
    };

    systemd.tmpfiles.rules = map (
      directory: "d ${directory} 0750 ${cfg.user} ${cfg.group} -"
    ) managedDirectories;

    systemd.services.lojix-daemon = {
      description = "Lojix deployment orchestrator daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ pkgs.coreutils pkgs.hostname pkgs.gitMinimal pkgs.nix pkgs.openssh pkgs.util-linux ];
      environment = optionalAttrs (cfg.sshAuthSocket != null) {
        SSH_AUTH_SOCK = cfg.sshAuthSocket;
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDirectoryPath;
        ExecStartPre = [ "${cfg.package}/bin/lojix-write-configuration ${startupRequest}" ];
        ExecStart = "${cfg.package}/bin/lojix-daemon ${cfg.startupArchivePath}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    # This service has no wantedBy relationship and is never part of daemon
    # startup. Starting it manually stops the daemon through Conflicts, resets
    # only cfg.storePath using the Lojix-owned path validator, then creates a
    # fresh v4 store. It never names or touches a Spirit database.
    systemd.services.lojix-reset-store = {
      description = "Reset the exact configured Lojix v4 store";
      conflicts = [ "lojix-daemon.service" ];
      after = [ "lojix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDirectoryPath;
        ExecStart = "${cfg.package}/bin/lojix-reset-store ${cfg.storePath}";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
