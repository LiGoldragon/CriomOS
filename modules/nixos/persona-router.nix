{
  config,
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
# nixosModules persona-router — the persona message/signal router daemon
# (router-daemon, the daemon-to-daemon delivery fabric), NOT the WiFi access
# point in modules/nixos/router/. Gated on the `PersonaRouter` node service.
#
# Hardwired for v1: the listen address, the co-resident criome socket, this
# router's stable identity, and the static peer + actor-home tables all come
# from the node-service payload. There is no discovery — every peer router and
# actor home is listed explicitly (RegisterRemoteRouter / RegisterActor in the
# startup bootstrap document the daemon applies at first runtime).
let
  inherit (lib)
    mkIf
    optionals
    concatMapStringsSep
    ;

  nodeServices = import ./node-services.nix { inherit lib; };
  services = horizon.node.services or [ ];
  personaRouterEnabled = nodeServices.has services "PersonaRouter";
  settings = nodeServices.payload services "PersonaRouter";

  runtimeDirectory = "/run/persona-router";
  stateDirectory = "/var/lib/persona-router";
  workingSocket = "${runtimeDirectory}/router.sock";
  metaSocket = "${runtimeDirectory}/meta.sock";
  supervisionSocket = "${runtimeDirectory}/supervision.sock";
  storePath = "${stateDirectory}/router.sema";
  bootstrapPath = "${runtimeDirectory}/bootstrap.rkyv";
  daemonConfigurationPath = "${runtimeDirectory}/router-daemon.rkyv";

  # Hardwired networking — the router-to-router TCP ingress address and the
  # stable identity carried into outbound attestations.
  listenAddress = settings.listenAddress or "0.0.0.0";
  listenPort = settings.listenPort or 7440;
  tailnetListenAddress = "${listenAddress}:${toString listenPort}";
  routerIdentity = settings.identity or config.networking.hostName;

  # The co-resident criome daemon's working socket the inbound ingress dials to
  # verify attestations (router milestone 3). Static path, not discovered.
  criomeSocketPath = settings.criomeSocketPath or "/run/criome/criome.sock";

  # The group that owns the co-resident criome working socket (0660). The
  # persona-router daemon joins it as a supplementary group so its milestone-3
  # criome client can connect to `criomeSocketPath` at runtime. Defaults to
  # criome's daemon group; the criome module must be co-resident (it creates the
  # group). Membership grants only socket access — criome's 0700 state dir and
  # 0600 master key stay owner-private.
  criomeSocketGroup = settings.criomeSocketGroup or "criome";

  # The group that owns the co-resident spirit daemon's working socket when
  # spirit is configured group-accessible (spirit.nix `workingSocketGroupAccess`,
  # UMask 0007). The persona-router daemon joins it so the mirror apply path
  # (authorized-record delivery to spirit's working socket) can connect. Null ⇒
  # the router does not dial a co-resident spirit (no supplementary group added).
  spiritSocketGroup = settings.spiritSocketGroup or null;

  # The Unix user the daemon records as the owner identity for owner-only meta
  # operations. Independent of the system user the process runs as.
  ownerUserIdentifier = settings.ownerUserIdentifier or 1000;

  # Hardwired tables (current router_write_bootstrap.rs shape — five root lists).
  # peers: [ { identity; address; } ].
  # actorHomes: [ { actor; process ? 0; home ? null; endpoint ? null; } ] where
  #   `home` names the peer the actor lives behind (null ⇒ local delivery) and
  #   `endpoint` names a co-resident component daemon's working socket to relay a
  #   verified inbound forward's routed objects to (null ⇒ routing/home only). A
  #   local criome recipient is `{ actor = <criome-actor>; home = null; endpoint
  #   = "/run/criome/criome.sock"; }` — the RegisterActor{ComponentSocket(...)}
  #   the mirror solicit-vote path delivers to.
  # grants: [ { source; destination; } ] — direct-message channel grants; a
  #   verified inbound forward from `source` is only DELIVERED to the
  #   locally-homed `destination` actor when such a grant exists (else it parks
  #   for adjudication and never reaches the component daemon).
  peers = settings.peers or [ ];
  actorHomes = settings.actorHomes or [ ];
  grants = settings.grants or [ ];
  hasBootstrap = peers != [ ] || actorHomes != [ ] || grants != [ ];

  daemonUser = "persona-router";
  daemonGroup = "persona-router";
  routerPackage = inputs.router.packages.${pkgs.stdenv.hostPlatform.system}.text;

  peerNota = concatMapStringsSep " " (peer: "(${peer.identity} ${peer.address})") peers;
  actorHomeNota = concatMapStringsSep " " (
    actorHome:
    let
      home = actorHome.home or null;
      homeNota = if home == null then "None" else "(Some ${home})";
      endpoint = actorHome.endpoint or null;
      endpointNota = if endpoint == null then "None" else "(Some (ComponentSocket ${endpoint}))";
    in
    "(${actorHome.actor} ${toString (actorHome.process or 0)} ${homeNota} ${endpointNota})"
  ) actorHomes;
  grantNota = concatMapStringsSep " " (grant: "(${grant.source} ${grant.destination})") grants;

  bootstrapRequestNota = pkgs.writeText "persona-router-bootstrap.nota" ''
    (BootstrapWriteRequest ${bootstrapPath} [ ${peerNota} ] [ ${actorHomeNota} ] [ ${grantNota} ])
  '';

  bootstrapField = if hasBootstrap then "(Some ${bootstrapPath})" else "None";
  daemonConfigurationNota = pkgs.writeText "persona-router-daemon-configuration.nota" ''
    (ConfigurationWriteRequest ${workingSocket} ${metaSocket} ${supervisionSocket} ${storePath} ${bootstrapField} ${toString ownerUserIdentifier} (Some ${tailnetListenAddress}) ${routerIdentity} (Some ${criomeSocketPath}) ${daemonConfigurationPath})
  '';

  writeBootstrap = "${routerPackage}/bin/router-write-bootstrap ${bootstrapRequestNota}";
  writeConfiguration = "${routerPackage}/bin/router-write-configuration ${daemonConfigurationNota}";
in
{
  config = mkIf personaRouterEnabled {
    environment.systemPackages = [ routerPackage ];

    users.groups.${daemonGroup} = { };
    users.users.${daemonUser} = {
      isSystemUser = true;
      group = daemonGroup;
      description = "Persona message/signal router daemon user";
      home = stateDirectory;
    };

    # Global firewall form — the hermetic VM runner has no tailscale0, so the
    # router TCP ingress must open on the global firewall, not a tailnet-scoped
    # interface (unlike mirror.nix).
    networking.firewall.allowedTCPPorts = [ listenPort ];

    systemd.services.persona-router = {
      description = "Persona message/signal router daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = daemonUser;
        Group = daemonGroup;
        # Join criome's group so the milestone-3 criome client can dial the
        # co-resident criome working socket (0660). criome must be co-resident.
        # Also join spirit's group when configured, so the mirror apply path can
        # dial the co-resident spirit working socket (spirit.nix
        # workingSocketGroupAccess). Membership grants only socket access.
        SupplementaryGroups = [
          criomeSocketGroup
        ] ++ optionals (spiritSocketGroup != null) [ spiritSocketGroup ];
        WorkingDirectory = stateDirectory;
        ExecStartPre = optionals hasBootstrap [ writeBootstrap ] ++ [ writeConfiguration ];
        ExecStart = "${routerPackage}/bin/router-daemon ${daemonConfigurationPath}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          stateDirectory
          runtimeDirectory
        ];
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDirectory} 0700 ${daemonUser} ${daemonGroup} -"
      "d ${runtimeDirectory} 0755 ${daemonUser} ${daemonGroup} -"
    ];
  };
}
