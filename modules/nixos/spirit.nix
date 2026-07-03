# spirit.nix — runs the spirit journal daemon as a hardened systemd service,
# modeled on modules/nixos/criome.nix. This is the missing first-class Spirit
# node module: only the now-dropped `mirror` daemon had a production module
# before this file (persistent-Spirit-mirror design, piece 6).
#
# DEPLOY DISCIPLINE. spirit-daemon takes exactly one pre-generated rkyv
# argument (no flags): the emitted `DaemonCommand::from_environment()` reads a
# single positional `SignalFile` path and parses no NOTA at the CLI, exactly
# like criome-daemon. This module seals a typed `ConfigurationWriteRequest`
# NOTA record to that rkyv artifact in `ExecStartPre` via the one-argument
# `spirit-write-configuration` deploy encoder (source-confirmed field order —
# `signal-spirit`'s `ConfigurationWriteRequest` / spirit's own
# `spirit-write-configuration.rs` and `tests/process_boundary.rs`:
# socket_path, meta_socket_path (Optional), database_path, trace_socket_path
# (Optional), authorization_mode, guardian_agent_configuration (Optional),
# output_path), then `ExecStart` launches `spirit-daemon <config.rkyv>`.
#
# TWO SOCKETS, DIFFERENT ORIGIN. Spirit's `SpiritDaemonConfiguration` carries
# no socket-mode field at all (unlike mirror's, which does): the generic
# emitted daemon binder (`spirit/src/schema/daemon.rs::DaemonBinder::bind`)
# hardcodes the META socket at 0600 for every component regardless of nix
# config, and leaves the WORKING socket at `BindingSurface::socket_mode()`'s
# default (`None` — "leaves the socket at the default umask-derived mode").
# Spirit's own `Configuration` (spirit's `src/config.rs`) does not override
# `socket_mode()`, so the working socket's real-world permission bits come
# from the unit's `UMask`, not from anything this module writes into the NOTA
# record. This module sets `UMask = "0077"` (owner-only working socket by
# default — the hardened, off-by-default posture the mirror design calls
# for). A later bead that needs a co-resident client (e.g. a router applying
# an authorized mirror record) to dial the working socket will need either a
# looser `UMask`/group arrangement here or a `signal-spirit` socket-mode field
# upstream; neither exists today, so this module does not claim group access
# it cannot deliver.
#
# TRACE SOCKET NOT EXPOSED. `trace_socket_path` is hardcoded `None`: the
# ordinary `packages.default` daemon binary is built with `--features
# agent-guardian` only (no `testing-trace`), so a configured trace socket
# would name a listener tier the running binary never compiles in. Spirit's
# flake also exposes a `packages.trace`/`trace-daemon` variant for that; wiring
# it is out of scope here (would be a distinct `package`/option pairing, not a
# field on this module's ordinary config).
#
# STORE. The durable SEMA journal lives at `/var/lib/spirit/spirit.sema` (the
# design's stated path). This module only provisions the owning 0700 state
# directory under the dedicated `spirit` user; the daemon creates and grows
# the store there itself and self-resumes across restarts (same store, same
# head) because the directory persists.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    types
    ;

  cfg = config.services.spirit;

  runtimeDir = "/run/spirit";
  stateDir = "/var/lib/spirit";
  socketPath = "${runtimeDir}/${cfg.socketName}";
  metaSocketPath = "${socketPath}.meta";
  storePath = "${stateDir}/spirit.sema";
  configRkyv = "${runtimeDir}/spirit-config.rkyv";

  guardianAgentModule = types.submodule {
    options = {
      agentSocketPath = mkOption {
        type = types.str;
        description = "The signal-agent guardian's socket path this spirit consults for gated authorization.";
      };

      providerName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The guardian agent's provider name (signal-spirit SpiritGuardianProviderName), a bare NOTA atom.";
      };

      modelName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The guardian agent's model name (signal-spirit SpiritGuardianModelName), a bare NOTA atom.";
      };

      timeoutMilliseconds = mkOption {
        type = types.ints.unsigned;
        default = 120000;
        description = "The guardian request timeout in milliseconds (signal-spirit SpiritGuardianTimeoutMilliseconds).";
      };

      maximumOutputTokens = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = "The guardian's maximum output tokens (signal-spirit SpiritGuardianMaximumOutputTokens).";
      };
    };
  };

  # (Optional Identity)-shaped Optional rendering for the guardian agent's
  # own optional sub-fields, then the whole guardian record as an Optional.
  guardianAgentNota =
    agent:
    let
      providerField = if agent.providerName == null then "None" else "(Some ${agent.providerName})";
      modelField = if agent.modelName == null then "None" else "(Some ${agent.modelName})";
      maximumOutputTokensField =
        if agent.maximumOutputTokens == null then
          "None"
        else
          "(Some ${toString agent.maximumOutputTokens})";
    in
    "(${agent.agentSocketPath} ${providerField} ${modelField} ${toString agent.timeoutMilliseconds} ${maximumOutputTokensField})";

  guardianAgentField =
    if cfg.guardianAgent == null then "None" else "(Some ${guardianAgentNota cfg.guardianAgent})";

  # The single ConfigurationWriteRequest NOTA record, in
  # spirit-write-configuration's field order: socket_path, meta_socket_path
  # (Optional), database_path, trace_socket_path (always None — see above),
  # authorization_mode, guardian_agent_configuration (Optional), output_path.
  configurationWriteRequestNota =
    "(ConfigurationWriteRequest ("
    + "${socketPath} (Some ${metaSocketPath}) ${storePath} None "
    + "${cfg.authorizationMode} ${guardianAgentField} ${configRkyv}"
    + "))";

  encodeConfigurationScript = pkgs.writeShellScript "spirit-encode-configuration" ''
    set -eu
    ${cfg.package}/bin/spirit-write-configuration ${lib.escapeShellArg configurationWriteRequestNota}
  '';
in
{
  options.services.spirit = {
    enable = mkEnableOption "the spirit journal daemon";

    package = mkOption {
      type = types.package;
      description = ''
        The spirit package providing `spirit-daemon` (the rkyv-only daemon),
        `spirit-write-configuration` (the deploy-time NOTA→rkyv encoder), and
        the `spirit`/`meta-spirit` CLI clients. The spirit flake's
        `packages.default` provides all four.
      '';
    };

    socketName = mkOption {
      type = types.str;
      default = "spirit.sock";
      description = ''
        The working Unix socket file name under ${runtimeDir}. The daemon
        binds this socket itself; its `${"\${socketName}"}.meta` sibling is
        always bound 0600 by the emitted daemon binder regardless of this
        module. Clients point `SPIRIT_SOCKET` at the working socket.
      '';
    };

    authorizationMode = mkOption {
      type = types.enum [
        "Gating"
        "Observing"
      ];
      default = "Gating";
      description = "The daemon's authorization mode (signal-spirit AuthorizationMode). Gating is spirit's own default.";
    };

    guardianAgent = mkOption {
      type = types.nullOr guardianAgentModule;
      default = null;
      description = ''
        The optional signal-agent guardian this spirit consults for gated
        record authorization (signal-spirit SpiritGuardianAgentConfiguration).
        Left null, the daemon runs with no guardian configured.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "spirit";
      description = "The dedicated system user the daemon runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "spirit";
      description = "The dedicated group the daemon runs as.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "spirit journal daemon user";
      home = stateDir;
    };

    systemd.services.spirit = {
      description = "spirit journal daemon";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = stateDir;
        ExecStartPre = [ encodeConfigurationScript ];
        ExecStart = "${cfg.package}/bin/spirit-daemon ${configRkyv}";
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
      # 0700 state dir: holds the durable SEMA store, preserved across
      # restarts so the daemon self-resumes on the same content-addressed head.
      "d ${stateDir} 0700 ${cfg.user} ${cfg.group} -"
      # 0755 runtime dir: holds the regenerated config rkyv + the two sockets
      # the daemon binds (working per UMask, meta always 0600).
      "d ${runtimeDir} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
