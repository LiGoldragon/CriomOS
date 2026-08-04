{ inputs, pkgs, ... }:

# Build-time round-trip guard for the typed Lojix service configuration. The
# daemon gets exactly one configuration-writer pre-start. Reset remains a
# separate manual service and must never become an implicit startup mutation.
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  lojixPackage = inputs.lojix.packages.${system}.default;
  configuration = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit inputs;
      horizon = {
        node = { };
      };
    };
    modules = [
      ../../modules/nixos/lojix.nix
      {
        system.stateVersion = "26.05";
        networking.hostName = "roundtrip-check";
        users.groups.lojix-fixture = { };
        users.users.lojix-fixture = {
          isSystemUser = true;
          group = "lojix-fixture";
        };
        services.lojix = {
          enable = true;
          user = "lojix-fixture";
          group = "lojix-fixture";
          ordinarySocketPath = "/run/lojix-fixture/ordinary.sock";
          ownerSocketPath = "/run/lojix-fixture/owner.sock";
          stateDirectoryPath = "/var/lib/lojix-fixture";
          storePath = "/var/lib/lojix-fixture/configured-lojix-store.db";
          startupArchivePath = "/run/lojix-fixture/startup.rkyv";
          daemonHost = "fixture-daemon";
          effectTimeoutSeconds = 2700;
        };
      }
    ];
  };

  lojixService = configuration.config.systemd.services.lojix-daemon;
  resetService = configuration.config.systemd.services.lojix-reset-store;
  execStartPre = lojixService.serviceConfig.ExecStartPre;
  configurationWriterCommand = builtins.elemAt execStartPre 0;
  storePath = configuration.config.services.lojix.storePath;
  ordinarySocketPath = configuration.config.services.lojix.ordinarySocketPath;
  ownerSocketPath = configuration.config.services.lojix.ownerSocketPath;
  startupArchivePath = configuration.config.services.lojix.startupArchivePath;
  daemonHost = configuration.config.services.lojix.daemonHost;
  effectTimeoutSeconds = configuration.config.services.lojix.effectTimeoutSeconds;
  startupRequest = "(ConfigurationWriteRequest (${ordinarySocketPath} 432 ${ownerSocketPath} 384 ${configuration.config.services.lojix.stateDirectoryPath} ${storePath} ${daemonHost} ${toString effectTimeoutSeconds} NoTestDefaults ${startupArchivePath}))";
  roundtripRequest = "(ConfigurationWriteRequest (${ordinarySocketPath} 432 ${ownerSocketPath} 384 ${configuration.config.services.lojix.stateDirectoryPath} ${storePath} ${daemonHost} ${toString effectTimeoutSeconds} NoTestDefaults startup.rkyv))";
in
assert (resetService.wantedBy or [ ]) == [ ];
pkgs.runCommand "lojix-daemon-config-roundtrip" { } ''
  set -eu

  test ${toString (builtins.length execStartPre)} = 1
  test ${toString (builtins.length resetService.conflicts)} = 1
  test ${lib.escapeShellArg (builtins.elemAt resetService.conflicts 0)} = lojix-daemon.service
  test ${lib.escapeShellArg resetService.serviceConfig.ExecStart} = \
    ${lib.escapeShellArg "${lojixPackage}/bin/lojix-reset-store ${lib.escapeShellArg "(ResetStore)"}"}
  test ${lib.escapeShellArg resetService.environment.LOJIX_CONFIGURATION} = \
    ${lib.escapeShellArg startupArchivePath}
  test ${lib.escapeShellArg configurationWriterCommand} = \
    ${lib.escapeShellArg "${lojixPackage}/bin/lojix-write-configuration ${lib.escapeShellArg startupRequest}"}
  test ${lib.escapeShellArg configuration.config.environment.variables.LOJIX_ORDINARY_SOCKET} = \
    ${lib.escapeShellArg ordinarySocketPath}
  test ${lib.escapeShellArg configuration.config.environment.variables.LOJIX_OWNER_SOCKET} = \
    ${lib.escapeShellArg ownerSocketPath}

  test ${toString effectTimeoutSeconds} = 2700
  test ${toString (builtins.length configuration.config.systemd.tmpfiles.rules)} = 2
  ${lojixPackage}/bin/lojix-write-configuration ${lib.escapeShellArg roundtripRequest} | grep -F '(ConfigurationWritten'
  test -s startup.rkyv

  touch "$out"
''
