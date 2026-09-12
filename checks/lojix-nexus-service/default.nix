{ inputs, pkgs, ... }:

# Build-time guard for the typed Lojix Nexus service. The Nexus starts with no
# arguments and self-configures from its own Sema store, so this unit gets no
# pre-start at all. Reset remains a separate manual service owning its own
# generated archive, and must never become an implicit startup mutation.
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
          package = lojixPackage;
          user = "lojix-fixture";
          group = "lojix-fixture";
          stateDirectoryPath = "/var/lib/lojix-fixture";
          runtimeDirectoryPath = "/run/lojix-fixture";
          nexusHost = "fixture-nexus";
        };
      }
    ];
  };

  lojixService = configuration.config.systemd.services.lojix;
  resetService = configuration.config.systemd.services.lojix-reset-store;
  settings = configuration.config.services.lojix;
  resetWriterCommand = builtins.elemAt resetService.serviceConfig.ExecStartPre 0;
  resetConfigurationRequest = "ConfigurationWriteRequest.{${settings.ordinarySocketPath} ${toString settings.ordinarySocketMode} ${settings.ownerSocketPath} ${toString settings.ownerSocketMode} ${settings.stateDirectoryPath} ${settings.storePath} ${settings.nexusHost} NoTestDefaults ${settings.resetConfigurationPath}}";
  roundtripRequest = "ConfigurationWriteRequest.{${settings.ordinarySocketPath} ${toString settings.ordinarySocketMode} ${settings.ownerSocketPath} ${toString settings.ownerSocketMode} ${settings.stateDirectoryPath} ${settings.storePath} ${settings.nexusHost} NoTestDefaults reset-configuration.rkyv}";
in
assert (resetService.wantedBy or [ ]) == [ ];
assert !(builtins.hasAttr "effectTimeoutSeconds" settings);
# The Nexus takes no argument and no pre-start. Both are asserted at evaluation
# so a reintroduced argument cannot reach a build.
assert lojixService.serviceConfig.ExecStart == "${lojixPackage}/bin/lojix-nexus";
assert (lojixService.serviceConfig.ExecStartPre or [ ]) == [ ];
pkgs.runCommand "lojix-nexus-service" { } ''
  set -eu

  test ${toString (builtins.length resetService.serviceConfig.ExecStartPre)} = 1
  test ${toString (builtins.length resetService.conflicts)} = 1
  test ${lib.escapeShellArg (builtins.elemAt resetService.conflicts 0)} = lojix.service
  test ${lib.escapeShellArg resetService.serviceConfig.ExecStart} = \
    ${lib.escapeShellArg "${lojixPackage}/bin/lojix-reset-store ResetStore"}
  test ${lib.escapeShellArg resetService.environment.LOJIX_CONFIGURATION} = \
    ${lib.escapeShellArg settings.resetConfigurationPath}
  test ${lib.escapeShellArg resetWriterCommand} = \
    ${lib.escapeShellArg "${lojixPackage}/bin/lojix-write-configuration ${lib.escapeShellArg resetConfigurationRequest}"}
  test ${lib.escapeShellArg configuration.config.environment.variables.LOJIX_ORDINARY_SOCKET} = \
    ${lib.escapeShellArg settings.ordinarySocketPath}
  test ${lib.escapeShellArg configuration.config.environment.variables.LOJIX_OWNER_SOCKET} = \
    ${lib.escapeShellArg settings.ownerSocketPath}

  test ${toString (builtins.length configuration.config.systemd.tmpfiles.rules)} = 2
  ${lojixPackage}/bin/lojix-write-configuration ${lib.escapeShellArg roundtripRequest} \
    | grep -F 'ConfigurationWritten.{'
  test -s reset-configuration.rkyv

  touch "$out"
''
