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
      horizon = { node = { }; };
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
          storePath = "/var/lib/lojix-fixture/lojix.sema";
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
  effectTimeoutSeconds = configuration.config.services.lojix.effectTimeoutSeconds;
  configurationWriterParts = lib.splitString " " configurationWriterCommand;
  moduleDotosPath = builtins.elemAt configurationWriterParts 1;
  moduleDotosText = lib.removeSuffix "\n" (builtins.readFile moduleDotosPath);
  dotosTokens = lib.splitString " " moduleDotosText;
  schemaBearingTokens = lib.init dotosTokens;
  roundtripDotosText = (lib.concatStringsSep " " schemaBearingTokens) + " startup.rkyv))";
  roundtripDotosFile = pkgs.writeText "lojix-daemon-config-roundtrip.dotos" roundtripDotosText;
in
assert (resetService.wantedBy or [ ]) == [ ];
pkgs.runCommand "lojix-daemon-config-roundtrip" { } ''
  set -eu

  test ${toString (builtins.length execStartPre)} = 1
  test ${toString (builtins.length resetService.conflicts)} = 1
  test ${lib.escapeShellArg (builtins.elemAt resetService.conflicts 0)} = lojix-daemon.service
  test ${lib.escapeShellArg resetService.serviceConfig.ExecStart} = \
    ${lib.escapeShellArg "${lojixPackage}/bin/lojix-reset-store ${storePath}"}

  test ${toString effectTimeoutSeconds} = 2700
  test ${toString (builtins.length configuration.config.systemd.tmpfiles.rules)} = 2
  printf '%s' ${lib.escapeShellArg moduleDotosText} | ${pkgs.gnugrep}/bin/grep -F 'fixture-daemon 2700 NoTestDefaults'

  # The exact module record with only the build-output field redirected.
  cat ${roundtripDotosFile}
  ${lojixPackage}/bin/lojix-write-configuration ${roundtripDotosFile} | grep -F '(ConfigurationWritten'
  test -s startup.rkyv

  touch "$out"
''
