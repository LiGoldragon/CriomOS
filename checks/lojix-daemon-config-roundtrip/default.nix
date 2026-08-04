{ inputs, pkgs, ... }:

# Build-time round-trip guard for the lojix-daemon module's hand-authored
# ConfigurationWriteRequest DOTOS (primary-dq1r).
#
# modules/nixos/lojix.nix authors the daemon's startup request as a Nix string
# that must positionally match the PINNED lojix `lojix-write-configuration`
# ConfigurationWriteRequest schema. The service must put its stopped-daemon
# v2 -> v3 migrator before that writer. `nix build` of a system closure never runs either
# command, so a gate or ordering regression would otherwise surface only at
# runtime.
#
# This check closes that gap: it evaluates the lojix-daemon module for a
# PersonaDevelopment node, takes the exact DOTOS the module emits, and feeds it
# to the pinned `lojix-write-configuration` binary. If the record no longer
# decodes against the pinned writer's positional schema, the writer exits
# non-zero and this check — hence the build — fails. Only the final output-path
# field is redirected to a build-writable relative path so the writer's plain
# `std::fs::write` (no directory creation, deploy target is /run/lojix) can
# land the rkyv in the sandbox; every schema-bearing field is exactly what the
# module authors.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  lojixPackage = inputs.lojix.packages.${system}.default;

  personaNode = {
    services = [
      {
        PersonaDevelopment = {
          capabilities = [
            { GitoliteServer = { }; }
          ];
        };
      }
    ];
  };

  configuration = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit inputs;
      horizon = {
        node = personaNode;
      };
    };
    modules = [
      ../../modules/nixos/lojix.nix
      {
        system.stateVersion = "26.05";
        networking.hostName = "roundtrip-check";
      }
    ];
  };

  lojixService = configuration.config.systemd.services.lojix-daemon;

  execStartPre = lojixService.serviceConfig.ExecStartPre;
  migrationGateCommand = builtins.elemAt execStartPre 0;
  configurationWriterCommand = builtins.elemAt execStartPre 1;
  storePath = "/var/lib/lojix/lojix.sema";
  # The second whitespace-token is the module's emitted DOTOS store path.
  configurationWriterParts = lib.splitString " " configurationWriterCommand;
  moduleDotosPath = builtins.elemAt configurationWriterParts 1;
  moduleDotosText = lib.removeSuffix "\n" (builtins.readFile moduleDotosPath);
  effectTimeoutSeconds = configuration.config.services.lojix.effectTimeoutSeconds;

  # The record ends with "<output_path>))". Swap only that last field (a plain
  # deploy path, not a schema surface) for a relative name so the pinned writer
  # writes into the build cwd; keep every preceding schema-bearing field verbatim.
  dotosTokens = lib.splitString " " moduleDotosText;
  schemaBearingTokens = lib.init dotosTokens;
  roundtripDotosText = (lib.concatStringsSep " " schemaBearingTokens) + " startup.rkyv))";
  roundtripDotosFile = pkgs.writeText "lojix-daemon-config-roundtrip.dotos" roundtripDotosText;
in
pkgs.runCommand "lojix-daemon-config-roundtrip" { } ''
  set -eu

  # The packaged migrator is the first pre-start command, ahead of configuration
  # encoding and daemon startup. It owns the permanent pre-v3 backup and both
  # transient staging sidecars; CriomOS must neither delete nor synthesize them.
  test ${toString (builtins.length execStartPre)} = 2
  ${pkgs.gnugrep}/bin/grep -Fx \
    ${lib.escapeShellArg "${lojixPackage}/bin/lojix-migrate-store ${storePath}"} \
    ${migrationGateCommand}
  ! ${pkgs.gnugrep}/bin/grep -F 'schema-v1' ${migrationGateCommand}
  ! ${pkgs.gnugrep}/bin/grep -F '/bin/mv' ${migrationGateCommand}
  ! ${pkgs.gnugrep}/bin/grep -F '/bin/rm' ${migrationGateCommand}

  test ${toString effectTimeoutSeconds} = 2700
  printf '%s' ${lib.escapeShellArg moduleDotosText} | ${pkgs.gnugrep}/bin/grep -F 'roundtrip-check 2700 NoTestDefaults'

  # The module's exact ConfigurationWriteRequest record (output path redirected).
  cat ${roundtripDotosFile}

  # Round-trip: the PINNED writer must decode this DOTOS and emit the rkyv. A
  # positional-schema drift between module and pin fails here, at build time.
  ${lojixPackage}/bin/lojix-write-configuration ${roundtripDotosFile} | grep -F '(ConfigurationWritten'
  test -s startup.rkyv

  touch "$out"
''
