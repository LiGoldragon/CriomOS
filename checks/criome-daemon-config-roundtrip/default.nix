{ inputs, pkgs, ... }:

# Build-time round-trip guard for the criome module's hand-authored
# CriomeConfigurationArtifact NOTA (primary-79z1.3).
#
# modules/nixos/criome.nix authors the daemon's startup config as a positional
# NOTA record that must match the PINNED criome `criome-encode-configuration`
# CriomeDaemonConfiguration schema. `nix build` of a system closure never runs
# that encoder (the `.nota` is only consumed at the unit's ExecStartPre), so a
# positional-schema drift between the module NOTA and a bumped criome pin would
# surface only at runtime (systemd ExecStartPre), crash-looping the daemon on the
# live host. This matters precisely now: the criome input was bumped to the
# founding-ceremony daemon (cee89b9b).
#
# This check closes that gap. It evaluates the criome module for a founding
# cohort node (nodeIdentity set, so the (Some (Host ...)) node_identity branch is
# exercised), takes the exact `.nota` the module emits, and feeds it to the
# pinned `criome-encode-configuration`. If the record no longer decodes against
# the pinned encoder's positional schema, the encoder exits non-zero and this
# check — hence the build — fails. Only the trailing output-path field is
# redirected to a build-writable relative path so the encoder's `std::fs::write`
# (no directory creation; deploy target is /run/criome) lands the rkyv in the
# sandbox; every schema-bearing field is exactly what the module authors.
#
# It also witnesses the CLEAN-GENESIS RETIREMENT: the criome service must carry
# NO ExecStartPost — the module seeds nothing (no RegisterIdentity, no
# AdmitContract, no cluster-root anchor) into the registry or contract store at
# deploy time, because the founding ceremony establishes the signer set at
# runtime.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  criomePackage = inputs.criome.packages.${system}.default;

  configuration = lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [
      ../../modules/nixos/criome.nix
      {
        system.stateVersion = "26.05";
        networking.hostName = "roundtrip-check";
        services.criome = {
          enable = true;
          package = criomePackage;
          # A distinct founding-cohort identity, so the emitted config exercises
          # the (Some (Host ...)) node_identity branch a founding node uses.
          nodeIdentity = "mirror-alpha";
        };
      }
    ];
  };

  criomeService = configuration.config.systemd.services.criome;

  # ExecStartPre = "${criomePackage}/bin/criome-encode-configuration ${notaFile}";
  # the second whitespace-token is the module's emitted .nota store path.
  execStartPreParts = lib.splitString " " criomeService.serviceConfig.ExecStartPre;
  moduleNotaPath = builtins.elemAt execStartPreParts 1;
  moduleNotaText = lib.removeSuffix "\n" (builtins.readFile moduleNotaPath);

  # The record is `(CriomeConfigurationArtifact (<8-field record>) <output_path>)`.
  # Swap only the trailing <output_path> token (a plain deploy path, not a schema
  # surface) for a relative name so the pinned encoder writes into the build cwd;
  # keep every preceding schema-bearing token verbatim. The final token carries a
  # single closing paren for the outer CriomeConfigurationArtifact.
  notaTokens = lib.splitString " " moduleNotaText;
  schemaBearingTokens = lib.init notaTokens;
  roundtripNotaText = (lib.concatStringsSep " " schemaBearingTokens) + " startup.rkyv)";
  roundtripNotaFile = pkgs.writeText "criome-daemon-config-roundtrip.nota" roundtripNotaText;

  # Retirement witness: no deploy-time seeding hook remains on the unit.
  hasExecStartPost = criomeService.serviceConfig ? ExecStartPost;
in
assert lib.assertMsg (!hasExecStartPost)
  "criome service must carry NO ExecStartPost — the clean-genesis founding posture seeds nothing at deploy time";
pkgs.runCommand "criome-daemon-config-roundtrip" { } ''
  set -eu

  # The module's exact CriomeConfigurationArtifact record (output path redirected).
  cat ${roundtripNotaFile}

  # Round-trip: the PINNED encoder must decode this NOTA and emit the rkyv. A
  # positional-schema drift between module and pin fails here, at build time.
  ${criomePackage}/bin/criome-encode-configuration ${roundtripNotaFile} | grep -F '(ArtifactWritten'
  test -s startup.rkyv

  touch "$out"
''
