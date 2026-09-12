{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;
  cfg = config.services.lojix;
  isDotosAtom = value: builtins.match "^[A-Za-z0-9_./:@+?=&%,-]+$" value != null;
  managedDirectories = lib.unique [
    cfg.stateDirectoryPath
    cfg.runtimeDirectoryPath
  ];

  # The Nexus starts with no arguments and self-configures: it opens its own
  # Sema store at the built-in location, persists the built-in configuration on
  # a fresh store, and resumes the persisted configuration on a populated one.
  # Nothing on this side writes that configuration. The values below are the
  # Nexus's own built-in defaults restated so that CriomOS's environment
  # variables, tmpfiles ownership and reset unit name exactly what the Nexus
  # opens; `checks/lojix-nexus-start` witnesses the agreement at runtime.
  nexusCommand = "${cfg.package}/bin/lojix-nexus";
  serviceUserGpgAgentSocket = "/run/user/$(${pkgs.coreutils}/bin/id -u)/gnupg/S.gpg-agent.ssh";
  serviceUserGpgAgentWrapper = pkgs.writeShellScript "lojix-nexus-service-user-gpg-agent" ''
    export SSH_AUTH_SOCK=${serviceUserGpgAgentSocket}
    exec ${nexusCommand}
  '';
  nexusExecStart =
    if cfg.sshAuthSocket != null && cfg.sshAuthSocket.mode == "service-user-gpg-agent" then
      "${serviceUserGpgAgentWrapper}"
    else
      nexusCommand;

  # `lojix-reset-store` takes no path: it reads the exact store from a generated
  # startup archive named by LOJIX_CONFIGURATION. That archive is the reset
  # unit's own private input, written immediately before the reset and never
  # read by the Nexus.
  resetConfigurationRequest = "ConfigurationWriteRequest.{${cfg.ordinarySocketPath} ${toString cfg.ordinarySocketMode} ${cfg.ownerSocketPath} ${toString cfg.ownerSocketMode} ${cfg.stateDirectoryPath} ${cfg.storePath} ${cfg.nexusHost} NoTestDefaults ${cfg.resetConfigurationPath}}";
in
{
  options.services.lojix = {
    enable = mkEnableOption "the Lojix Nexus";

    package = mkOption {
      type = types.package;
      description = "The versioned Lojix package providing the Nexus, clients, writer, and reset primitive.";
    };

    user = mkOption {
      type = types.str;
      description = "Existing unprivileged account that owns the Lojix Nexus and store.";
    };

    group = mkOption {
      type = types.str;
      description = "Existing group used by the Lojix Nexus and owner socket.";
    };

    stateDirectoryPath = mkOption {
      type = types.str;
      default = "/var/lib/lojix";
      description = ''
        Absolute directory the Nexus opens as its state base. This must equal
        the Nexus's own built-in state directory: the Nexus derives it from
        XDG_STATE_HOME or falls back to this path, and nothing here can change
        that choice. Changing it requires a matching Lojix change.
      '';
    };

    runtimeDirectoryPath = mkOption {
      type = types.str;
      default = "/run/lojix";
      description = ''
        Absolute directory the Nexus binds both sockets in. This must equal the
        Nexus's own built-in runtime directory: the Nexus derives it from
        XDG_RUNTIME_DIR or falls back to this path.
      '';
    };

    nexusHost = mkOption {
      type = types.str;
      description = "Explicit Nexus host identity used only for self-switch safety.";
    };

    storePath = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.stateDirectoryPath}/lojix.sema";
      description = "The exact Sema file the Nexus opens. Derived; the Nexus fixes the basename.";
    };

    ordinarySocketPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.runtimeDirectoryPath}/ordinary.sock";
      description = "The ordinary socket the Nexus binds. Derived; the Nexus fixes the basename.";
    };

    ownerSocketPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.runtimeDirectoryPath}/meta.sock";
      description = "The owner (meta) socket the Nexus binds. Derived; the Nexus fixes the basename.";
    };

    ordinarySocketMode = mkOption {
      type = types.ints.between 0 511;
      readOnly = true;
      default = 432;
      description = "The ordinary socket mode the Nexus applies (0o660). Restated for the reset archive.";
    };

    ownerSocketMode = mkOption {
      type = types.ints.between 0 504;
      readOnly = true;
      default = 384;
      description = "The owner socket mode the Nexus applies (0o600). Restated for the reset archive.";
    };

    resetConfigurationPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.stateDirectoryPath}/reset-configuration.rkyv";
      description = "Private generated archive naming the store for the manual reset unit.";
    };

    sshAuthSocket = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            mode = mkOption {
              type = types.enum [
                "path"
                "service-user-gpg-agent"
              ];
              description = "Whether to use an explicit absolute SSH-agent socket path or the configured service user's GPG-agent socket.";
            };
            path = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Explicit absolute SSH-agent socket path when mode is path.";
            };
          };
        }
      );
      default = null;
      description = "Optional SSH-agent endpoint supplied to the Nexus.";
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
        assertion = lib.hasPrefix "/" cfg.stateDirectoryPath && lib.hasPrefix "/" cfg.runtimeDirectoryPath;
        message = "services.lojix state and runtime directories must be absolute";
      }
      {
        assertion =
          cfg.sshAuthSocket == null
          || (cfg.sshAuthSocket.mode == "service-user-gpg-agent" && cfg.sshAuthSocket.path == null)
          || (
            cfg.sshAuthSocket.mode == "path"
            && cfg.sshAuthSocket.path != null
            && lib.hasPrefix "/" cfg.sshAuthSocket.path
          );
        message = "services.lojix.sshAuthSocket must be service-user-gpg-agent or an explicit absolute path";
      }
      {
        assertion = lib.all (directory: directory != "/") managedDirectories;
        message = "services.lojix managed state and runtime directories must not be the filesystem root";
      }
      {
        assertion =
          lib.all isDotosAtom [
            cfg.ordinarySocketPath
            cfg.ownerSocketPath
            cfg.stateDirectoryPath
            cfg.storePath
            cfg.resetConfigurationPath
            cfg.nexusHost
          ]
          && (
            cfg.sshAuthSocket == null
            || cfg.sshAuthSocket.mode == "service-user-gpg-agent"
            || isDotosAtom cfg.sshAuthSocket.path
          );
        message = "services.lojix paths and nexusHost must be nonempty DATOM atoms without whitespace or control syntax";
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

    systemd.services.lojix = {
      description = "Lojix Nexus";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.coreutils
        pkgs.hostname
        pkgs.gitMinimal
        pkgs.nix
        pkgs.openssh
        pkgs.util-linux
      ];
      environment = optionalAttrs (cfg.sshAuthSocket != null && cfg.sshAuthSocket.mode == "path") {
        SSH_AUTH_SOCK = cfg.sshAuthSocket.path;
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDirectoryPath;
        ExecStart = nexusExecStart;
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    # This service has no wantedBy relationship and is never part of Nexus
    # startup. Starting it manually stops the Nexus through Conflicts, writes
    # its own private archive naming the exact configured store, and passes one
    # pathless reset object. It recreates recognised pre-v5 Lojix stores,
    # reports current v5 stores without touching their data, and never names or
    # touches a Spirit database.
    systemd.services.lojix-reset-store = {
      description = "Recreate the exact configured pre-v5 Lojix store";
      conflicts = [ "lojix.service" ];
      after = [ "lojix.service" ];
      environment = {
        LOJIX_CONFIGURATION = cfg.resetConfigurationPath;
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDirectoryPath;
        ExecStartPre = [
          "${cfg.package}/bin/lojix-write-configuration ${lib.escapeShellArg resetConfigurationRequest}"
        ];
        ExecStart = "${cfg.package}/bin/lojix-reset-store ResetStore";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
