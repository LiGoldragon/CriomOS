# criome.nix — runs the criome BLS-attestation daemon as a hardened systemd
# service, modeled on modules/nixos/mirror.nix.
#
# DEPLOY DISCIPLINE. criome-daemon takes exactly one pre-generated rkyv
# `SignalFile` argument and parses no NOTA (no flags). So the typed
# `CriomeDaemonConfiguration` this module authors as a single positional NOTA
# record is written to an inspectable `criome-config.nota` store artifact, then
# sealed into the rkyv artifact in `ExecStartPre` by the one-argument
# `criome-encode-configuration` deploy encoder (which reads that `.nota` file),
# and `ExecStart` launches `criome-daemon <config.rkyv>`. This is the criome
# sibling of mirror's `mirror-write-configuration` ExecStartPre step. Emitting
# the NOTA as a named file (rather than an embedded shell argument) lets the
# `criome-daemon-config-roundtrip` flake check feed the module's exact record to
# the pinned encoder and fail the build on any positional-schema drift.
#
# TWO SOCKETS. The daemon binds its working socket (`${socketName}`) at 0660 —
# a shared IPC surface a co-resident persona-router (in criome's group) dials,
# and the PUBLIC read surface that answers `ObserveNodePublicKey` (a node's
# Criome master pubkey is read here during the founding ceremony) — and its meta
# socket (`${socketName}.meta`) at 0600, the OWNER-ONLY control surface that
# answers `AcceptRootFounding` (the explicit owner accept that founds the root,
# no auto-approval), both under ${runtimeDir}. A co-resident persona-router
# points its `criome_socket_path` at the working socket and joins criome's group.
#
# KEY CUSTODY (Spirit psc6 / key-custody q1le). criome's master signing key is
# generated on first run and persisted at the store-derived path
# (store `…/criome.sema` ⇒ key `…/criome.masterkey`) at mode 0600 by the daemon
# itself. This module only provisions the owning state directory (0700) under
# the dedicated `criome` user so the daemon can create the key there. The secret
# never leaves criome and is never placed in the Nix store.
#
# CLEAN GENESIS — FOUNDED ROOT, NOT HAND-SEEDED (spec A1/A3, bead primary-79z1.3).
# The authorized signer set is no longer hand-seeded at deploy time. The founding
# ceremony (`AcceptRootFounding` on the owner-only meta socket, unanimous +
# explicit owner accept) establishes the persistent root contract and seeds the
# identity registry from its founding cohort keys, replacing the former single-key
# `ClusterRoot` admission anchor. So this module RETIRES the old hand-seeding
# surface entirely — no `RegisterIdentity` peer seeds, no `AdmitContract` quorum
# contract, no `clusterRootPublicKey` anchor — because those wrote a pre-`parent`
# (schema-v4) contract/identity shape that would fight the ceremony and cannot be
# re-digested under the parent-bearing v5 `Contract`. `cluster_root` is therefore
# always `None` in the emitted config. A founding node must set `nodeIdentity` to
# its distinct `Host(<name>)` so it signs as a distinct cohort member.
#
# The v5 daemon REFUSES to open a pre-`parent` (v4) contract store, so a
# clean-genesis boot requires an empty `${stateDir}` on first start. A fresh
# TestVm disk satisfies this by construction; the daemon then self-registers its
# own identity, awaits founding, and — once founded — persists the root and
# self-resumes it across reboot (it never re-founds). This module deliberately
# adds NO store wipe: an unconditional wipe would destroy the founded root on
# every boot. A test VM carrying a stale v4 store (nothing to preserve) is reset
# by recreating its disk, an operator/host action outside this module.

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

  # The identity this criome signs attestations as. Null keeps the daemon's
  # historical Host("criome") default (single-node use); a founding cohort node
  # MUST set a distinct per-node identity (e.g. "mirror-alpha") so it signs as a
  # distinct `Host(<name>)` cohort member and a peer criome that has read this
  # node's master pubkey (via `ObserveNodePublicKey`) can enroll and cross-verify
  # it. Rendered as the (Optional Identity) NOTA field.
  nodeIdentityField =
    if cfg.nodeIdentity == null then "None" else "(Some (Host ${cfg.nodeIdentity}))";

  # The single typed CriomeDaemonConfiguration record as positional NOTA, in the
  # signal-criome schema field order: socket_path, store_path, meta_socket_path
  # (Optional), cluster_root (Optional — always None under founding), Authorization-
  # Mode, node_identity (Optional Identity), router submission (Optional), and
  # quorum window (Optional). The latter two stay absent until CriomOS projects
  # their deployment configuration; absence selects Criome's own safe defaults.
  # The encoder wraps it in a CriomeConfigurationArtifact carrying the rkyv
  # output path and seals it.
  configurationArtifactNota =
    "(CriomeConfigurationArtifact "
    + "(${socketPath} ${storePath} (Some ${metaSocketPath}) None ${cfg.authorizationMode} ${nodeIdentityField} None None) "
    + "${configRkyv})";

  # The record as an inspectable, checkable .nota artifact. The encoder classifies
  # an existing path argument as a NotaFile and reads it (triad-runtime
  # RawArgument::from_single), so ExecStartPre passes this file directly rather
  # than an embedded shell argument. The `.nota` suffix documents the content
  # type. Passing the file as the sole ExecStartPre token (no wrapper script) lets
  # `criome-daemon-config-roundtrip` read the exact `.nota` from the emitted unit.
  configurationArtifactNotaFile = pkgs.writeText "criome-config.nota" configurationArtifactNota;

  encodeConfigurationCommand =
    "${cfg.package}/bin/criome-encode-configuration ${configurationArtifactNotaFile}";
in
{
  options.services.criome = {
    enable = mkEnableOption "the criome BLS-attestation daemon";

    package = mkOption {
      type = types.package;
      description = ''
        The criome package providing `criome-daemon` (the rkyv-only daemon),
        `criome-encode-configuration` (the deploy-time NOTA→rkyv encoder), and
        the `criome` CLI client (the working-socket client used to read
        `ObserveNodePublicKey`). The criome flake's `packages.default` provides
        all three. Note: no meta-socket CLI ships in `packages.default` today, so
        `AcceptRootFounding` (the founding accept) has no operator-facing tool yet
        — see primary-79z1.3 return notes.
      '';
    };

    socketName = mkOption {
      type = types.str;
      default = "criome.sock";
      description = ''
        The working Unix socket file name under ${runtimeDir}. The daemon binds
        this socket at 0660 (the shared IPC + public read surface) — and its
        `${"\${socketName}"}.meta` sibling at 0600 (owner-only) — itself; clients
        (e.g. a co-resident persona-router) point their `criome_socket_path` at
        the working socket.
      '';
    };

    authorizationMode = mkOption {
      type = types.enum [
        "Quorum"
        "AutoApprove"
        "ClientApproval"
      ];
      default = "Quorum";
      description = ''
        The daemon's authorization mode (signal-criome AuthorizationMode). Quorum
        is correct for a founded root: the founded root contract is a Threshold
        evaluated under quorum.
      '';
    };

    nodeIdentity = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "mirror-alpha";
      description = ''
        The `Host` principal name this criome signs attestations as. Left null,
        the daemon keeps its historical `Host("criome")` identity (single-node
        deployments are unchanged). A founding cohort node MUST set a distinct
        per-node name (e.g. "mirror-alpha") so it signs as a distinct
        `Host(<name>)` cohort member; a peer criome that has enrolled this node's
        master public key under `Host(<name>)` then cross-verifies its
        attestations, while an unregistered or foreign key is refused fail-closed.
        For a co-resident persona-router's forward path to verify on the peer,
        this name must equal the local persona-router's `router_identity`.
      '';
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
        # Seal the typed NOTA config into the rkyv the daemon reads. No
        # ExecStartPost: the founding ceremony (owner-driven, over the meta
        # socket) establishes the signer set at runtime — the module seeds
        # nothing into the registry or contract store at deploy time.
        ExecStartPre = encodeConfigurationCommand;
        ExecStart = "${cfg.package}/bin/criome-daemon ${configRkyv}";
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
      # master key, preserved across restarts so the daemon self-resumes and,
      # once founded, re-verifies its persisted root (never re-founds).
      "d ${stateDir} 0700 ${cfg.user} ${cfg.group} -"
      # 0755 runtime dir: holds the regenerated config rkyv + the two sockets the
      # daemon binds (working 0660, meta 0600).
      "d ${runtimeDir} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
