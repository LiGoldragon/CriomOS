{ inputs, pkgs, ... }:

# Build-time round-trip guard for the lojix-daemon module's hand-authored
# ConfigurationWriteRequest NOTA (primary-dq1r).
#
# modules/nixos/lojix.nix authors the daemon's startup request as a Nix string
# that must positionally match the PINNED lojix `lojix-write-configuration`
# ConfigurationWriteRequest schema. `nix build` of a system closure never runs
# that writer (the NOTA is only `pkgs.writeText` text consumed at the unit's
# ExecStartPre), so today a schema drift between the module NOTA and a bumped
# lojix pin would surface only at runtime (systemd ExecStartPre), crash-looping
# the daemon on the live host.
#
# This check closes that gap: it evaluates the lojix-daemon module for a
# PersonaDevelopment node, takes the exact NOTA the module emits, and feeds it
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

  # ExecStartPre = "${lojixPackage}/bin/lojix-write-configuration ${startupRequest}";
  # the second whitespace-token is the module's emitted NOTA store path.
  execStartPreParts = lib.splitString " " lojixService.serviceConfig.ExecStartPre;
  moduleNotaPath = builtins.elemAt execStartPreParts 1;
  moduleNotaText = lib.removeSuffix "\n" (builtins.readFile moduleNotaPath);

  # The record ends with "<output_path>))". Swap only that last field (a plain
  # deploy path, not a schema surface) for a relative name so the pinned writer
  # writes into the build cwd; keep every preceding schema-bearing field verbatim.
  notaTokens = lib.splitString " " moduleNotaText;
  schemaBearingTokens = lib.init notaTokens;
  roundtripNotaText = (lib.concatStringsSep " " schemaBearingTokens) + " startup.rkyv))";
  roundtripNotaFile = pkgs.writeText "lojix-daemon-config-roundtrip.nota" roundtripNotaText;
in
pkgs.runCommand "lojix-daemon-config-roundtrip" { } ''
  set -eu

  # The module's exact ConfigurationWriteRequest record (output path redirected).
  cat ${roundtripNotaFile}

  # Round-trip: the PINNED writer must decode this NOTA and emit the rkyv. A
  # positional-schema drift between module and pin fails here, at build time.
  ${lojixPackage}/bin/lojix-write-configuration ${roundtripNotaFile} | grep -F '(ConfigurationWritten'
  test -s startup.rkyv

  touch "$out"
''
