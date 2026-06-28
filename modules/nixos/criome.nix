# criome.nix — runs the criome BLS-attestation daemon as a hardened systemd
# service, modeled on modules/nixos/mirror.nix.
#
# DEPLOY DISCIPLINE. criome-daemon takes exactly one pre-generated rkyv
# `SignalFile` argument and parses no NOTA (no flags). So the typed
# `CriomeDaemonConfiguration` this module authors as a single positional NOTA
# record is sealed into the rkyv artifact in `ExecStartPre` by the one-argument
# `criome-encode-configuration` deploy encoder, then `ExecStart` launches
# `criome-daemon <config.rkyv>`. This is the criome sibling of mirror's
# `mirror-write-configuration` ExecStartPre step.
#
# TWO 0600 SOCKETS. The daemon binds its working socket (`${socketName}`) and
# its meta socket (`${socketName}.meta`) under ${runtimeDir}, each at mode 0600,
# itself (`bind_private_socket`). A co-resident persona-router points its
# `criome_socket_path` at the working socket.
#
# KEY CUSTODY (Spirit psc6 / key-custody q1le). criome's master signing key is
# generated on first run and persisted at the store-derived path
# (store `…/criome.sema` ⇒ key `…/criome.masterkey`) at mode 0600 by the daemon
# itself. This module only provisions the owning state directory (0700) under
# the dedicated `criome` user so the daemon can create the key there. The secret
# never leaves criome and is never placed in the Nix store.
#
# CROSS-INSTANCE IDENTITY SEED. `peerIdentitySeeds` issues a `RegisterIdentity`
# for each peer criome's public key over the working socket in `ExecStartPost`,
# the v1 hardwired trust anchor: with no `clusterRootPublicKey` configured the
# registry admits the seed unconditionally; with one configured the seed must
# carry a cluster-root admission. Empty for a single criome node.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption mkEnableOption types;

  cfg = config.services.criome;

  runtimeDir = "/run/criome";
  stateDir = "/var/lib/criome";
  socketPath = "${runtimeDir}/${cfg.socketName}";
  metaSocketPath = "${socketPath}.meta";
  storePath = "${stateDir}/criome.sema";
  configRkyv = "${runtimeDir}/criome-config.rkyv";

  clusterRootField =
    if cfg.clusterRootPublicKey == null then "None" else "(Some ${cfg.clusterRootPublicKey})";

  # The single typed CriomeDaemonConfiguration record as positional NOTA, in the
  # signal-criome schema field order: socket_path, store_path, meta_socket_path
  # (Optional), cluster_root (Optional), AuthorizationMode. The encoder wraps it
  # in a CriomeConfigurationArtifact carrying the rkyv output path and seals it.
  configurationArtifactNota =
    "(CriomeConfigurationArtifact "
    + "(${socketPath} ${storePath} (Some ${metaSocketPath}) ${clusterRootField} ${cfg.authorizationMode}) "
    + "${configRkyv})";

  encodeConfigurationScript = pkgs.writeShellScript "criome-encode-configuration" ''
    set -eu
    ${cfg.package}/bin/criome-encode-configuration ${lib.escapeShellArg configurationArtifactNota}
  '';

  # One ExecStartPost per peer seed: wait for the freshly-bound working socket,
  # then register the peer identity. Re-running on restart is harmless (a
  # duplicate Active identity returns a rejection reply, not a transport error).
  seedScript =
    seed:
    pkgs.writeShellScript "criome-seed-${seed.name}" ''
      set -eu
      for _ in $(seq 1 100); do
        [ -S ${lib.escapeShellArg socketPath} ] && break
        sleep 0.1
      done
      CRIOME_SOCKET=${lib.escapeShellArg socketPath} ${cfg.package}/bin/criome \
        ${
          lib.escapeShellArg "(RegisterIdentity ((Host ${seed.name}) ${seed.publicKey} ${seed.fingerprint} ${seed.purpose} None))"
        }
    '';

  seedModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "The peer criome host identity name (the `Host` principal registered).";
      };
      publicKey = mkOption {
        type = types.str;
        description = "The peer criome's BLS public key (hex), a bare NOTA atom.";
      };
      fingerprint = mkOption {
        type = types.str;
        description = "The peer key fingerprint, a bare NOTA atom.";
      };
      purpose = mkOption {
        type = types.enum [
          "CriomeRoot"
          "PersonaRequest"
          "AgentRequest"
          "ReleaseAuthorization"
          "HostPublication"
        ];
        default = "CriomeRoot";
        description = "The peer key's purpose (signal-criome KeyPurpose).";
      };
    };
  };
in
{
  options.services.criome = {
    enable = mkEnableOption "the criome BLS-attestation daemon";

    package = mkOption {
      type = types.package;
      description = ''
        The criome package providing `criome-daemon` (the rkyv-only daemon),
        `criome-encode-configuration` (the deploy-time NOTA→rkyv encoder), and
        the `criome` CLI client (used for the peer-identity seed). The criome
        flake's `packages.default` provides all three.
      '';
    };

    socketName = mkOption {
      type = types.str;
      default = "criome.sock";
      description = ''
        The working Unix socket file name under ${runtimeDir}. The daemon binds
        this socket — and its `${"\${socketName}"}.meta` sibling — at 0600
        itself; clients (e.g. a co-resident persona-router) point their
        `criome_socket_path` at the working socket.
      '';
    };

    clusterRootPublicKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "b1c2...";
      description = ''
        The cluster-root BLS public key (hex), the trust anchor whose signature
        admits keys into the registry. A bare NOTA atom. Left null starts the
        daemon without a configured anchor (virgin bootstrap), under which the
        registry admits `peerIdentitySeeds` unconditionally.
      '';
    };

    authorizationMode = mkOption {
      type = types.enum [
        "Quorum"
        "AutoApprove"
        "ClientApproval"
      ];
      default = "Quorum";
      description = "The daemon's authorization mode (signal-criome AuthorizationMode).";
    };

    user = mkOption {
      type = types.str;
      default = "criome";
      description = "The dedicated system user the daemon runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "criome";
      description = "The dedicated group the daemon runs as.";
    };

    peerIdentitySeeds = mkOption {
      type = types.listOf seedModule;
      default = [ ];
      description = ''
        Peer criome identities to seed into this daemon's registry at startup
        (the v1 hardwired cross-instance trust anchor). Each entry issues a
        `RegisterIdentity` over the working socket in `ExecStartPost`. Empty for
        a single criome node.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "criome BLS-attestation daemon user";
      home = stateDir;
    };

    systemd.services.criome = {
      description = "criome BLS-attestation daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = stateDir;
        ExecStartPre = [ encodeConfigurationScript ];
        ExecStart = "${cfg.package}/bin/criome-daemon ${configRkyv}";
        ExecStartPost = map seedScript cfg.peerIdentitySeeds;
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          stateDir
          runtimeDir
        ];
      };
    };

    systemd.tmpfiles.rules = [
      # 0700 state dir: holds the durable SEMA store and the daemon's 0600
      # master key, preserved across restarts so the daemon self-resumes.
      "d ${stateDir} 0700 ${cfg.user} ${cfg.group} -"
      # 0755 runtime dir: holds the regenerated config rkyv + the two 0600
      # sockets the daemon binds.
      "d ${runtimeDir} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
