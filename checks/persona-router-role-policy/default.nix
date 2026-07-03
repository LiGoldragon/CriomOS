{ inputs, pkgs, ... }:

# Witness for modules/nixos/persona-router.nix. Evaluates a nixosSystem with
# only the persona-router module against a synthetic horizon, then asserts the
# systemd unit shape and the exact hardwired NOTA the deploy text edges receive.
# The `${routerPackage}/bin/...` store-path references in ExecStart/ExecStartPre
# force the router package (router-daemon + the two write tools) to build, so a
# green here proves both that the module evaluates and that the router service
# closure builds.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseNode = {
    services = [ ];
  };

  # A node carrying only an unrelated service must NOT start the persona router.
  mirrorOnlyNode = {
    services = [
      { TailnetClient = { }; }
    ];
  };

  personaRouterNode = {
    services = [
      {
        PersonaRouter = {
          identity = "router-a";
          listenPort = 7440;
          criomeSocketPath = "/run/criome/criome.sock";
          peers = [
            {
              identity = "router-b";
              address = "192.168.1.20:7440";
            }
          ];
          actorHomes = [
            {
              actor = "mirror";
              process = 0;
              home = "router-b";
            }
            # Local criome recipient: a co-resident criome actor with a
            # ComponentSocket endpoint (no home ⇒ local delivery). This is the
            # RegisterActor{ComponentSocket(criome_socket)} the mirror
            # solicit-vote path delivers a verified inbound forward's routed
            # objects to (primary-nbmq.9 criome-recipient wiring).
            {
              actor = "criome-router-a";
              process = 0;
              endpoint = "/run/criome/criome.sock";
            }
          ];
          # The direct-message channel grant that authorizes the peer criome's
          # verified inbound forward to be DELIVERED to the local criome actor.
          grants = [
            {
              source = "criome-router-b";
              destination = "criome-router-a";
            }
          ];
        };
      }
    ];
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/persona-router.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  baseConfiguration = configurationFor baseNode;
  mirrorOnlyConfiguration = configurationFor mirrorOnlyNode;
  personaRouterConfiguration = configurationFor personaRouterNode;

  servicePresent =
    configuration: builtins.hasAttr "persona-router" configuration.config.systemd.services;

  service = personaRouterConfiguration.config.systemd.services.persona-router;
  serviceConfig = service.serviceConfig;

  execStartPre = serviceConfig.ExecStartPre;
  bootstrapCommand = builtins.elemAt execStartPre 0;
  configurationCommand = builtins.elemAt execStartPre 1;
  bootstrapNota = builtins.readFile (builtins.elemAt (lib.splitString " " bootstrapCommand) 1);
  configurationNota = builtins.readFile (
    builtins.elemAt (lib.splitString " " configurationCommand) 1
  );

  systemPackageNames = lib.concatStringsSep " " (
    map (package: package.pname or package.name or "unnamed")
      personaRouterConfiguration.config.environment.systemPackages
  );
  tmpfiles = lib.concatStringsSep "\n" personaRouterConfiguration.config.systemd.tmpfiles.rules;
  allowedTcpPorts =
    personaRouterConfiguration.config.networking.firewall.allowedTCPPorts or [ ];
in
pkgs.runCommand "persona-router-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool (servicePresent baseConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent mirrorOnlyConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent personaRouterConfiguration))} = true

  test ${lib.escapeShellArg service.description} = 'Persona message/signal router daemon'
  test ${lib.escapeShellArg serviceConfig.User} = persona-router
  test ${lib.escapeShellArg serviceConfig.Group} = persona-router
  test ${lib.escapeShellArg (bool serviceConfig.NoNewPrivileges)} = true

  printf '%s' ${lib.escapeShellArg bootstrapCommand} | grep -F '/bin/router-write-bootstrap'
  printf '%s' ${lib.escapeShellArg configurationCommand} | grep -F '/bin/router-write-configuration'
  printf '%s' ${lib.escapeShellArg serviceConfig.ExecStart} | grep -F '/bin/router-daemon'
  printf '%s' ${lib.escapeShellArg serviceConfig.ExecStart} | grep -F '/run/persona-router/router-daemon.rkyv'

  printf '%s' ${lib.escapeShellArg configurationNota} | grep -F '(ConfigurationWriteRequest /run/persona-router/router.sock /run/persona-router/meta.sock /run/persona-router/supervision.sock /var/lib/persona-router/router.sema (Some /run/persona-router/bootstrap.rkyv) 1000 (Some 0.0.0.0:7440) router-a (Some /run/criome/criome.sock) /run/persona-router/router-daemon.rkyv)'
  printf '%s' ${lib.escapeShellArg bootstrapNota} | grep -F '(BootstrapWriteRequest /run/persona-router/bootstrap.rkyv [ (router-b 192.168.1.20:7440) ] [ (mirror 0 (Some router-b) None) (criome-router-a 0 None (Some (ComponentSocket /run/criome/criome.sock))) ] [ (criome-router-b criome-router-a) ])'
  ! printf '%s' ${lib.escapeShellArg configurationNota} | grep -F '"'

  printf '%s' ${lib.escapeShellArg systemPackageNames} | grep -F router
  printf '%s' ${lib.escapeShellArg tmpfiles} | grep -F 'd /var/lib/persona-router 0700 persona-router persona-router -'
  printf '%s' ${lib.escapeShellArg tmpfiles} | grep -F 'd /run/persona-router 0755 persona-router persona-router -'
  printf '%s' ${lib.escapeShellArg (builtins.toJSON allowedTcpPorts)} | grep -F 7440

  touch "$out"
''
