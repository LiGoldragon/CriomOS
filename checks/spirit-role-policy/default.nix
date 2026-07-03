{ inputs, pkgs, ... }:

# Witness for modules/nixos/spirit.nix. Evaluates a nixosSystem carrying only
# the spirit module (a plain enable-option service, not horizon-gated — unlike
# mirror/persona-router), then asserts the systemd unit shape and the exact
# ConfigurationWriteRequest NOTA the ExecStartPre encode script embeds. The
# `${spiritPackage}/bin/...` store-path references force the real spirit
# package (spirit-daemon + spirit-write-configuration) to build, so a green
# here proves both that the module evaluates and that the spirit service
# closure builds.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  spiritPackage = inputs.spirit.packages.${system}.default;

  configurationFor =
    serviceConfig:
    lib.nixosSystem {
      inherit system;
      modules = [
        ../../modules/nixos/spirit.nix
        {
          system.stateVersion = "26.05";
          services.spirit = serviceConfig;
        }
      ];
    };

  disabledConfiguration = configurationFor { package = spiritPackage; };
  enabledConfiguration = configurationFor {
    enable = true;
    package = spiritPackage;
  };
  guardianConfiguration = configurationFor {
    enable = true;
    package = spiritPackage;
    guardianAgent = {
      agentSocketPath = "/run/agent/agent.sock";
      providerName = "criomos-local";
      timeoutMilliseconds = 60000;
    };
  };
  # workingSocketGroupAccess flips the unit UMask so a co-resident router (in
  # the spirit group) can dial the working socket (primary-nbmq.9).
  groupAccessConfiguration = configurationFor {
    enable = true;
    package = spiritPackage;
    workingSocketGroupAccess = true;
  };

  servicePresent = configuration: builtins.hasAttr "spirit" configuration.config.systemd.services;

  service = enabledConfiguration.config.systemd.services.spirit;
  serviceConfig = service.serviceConfig;

  # ExecStartPre is a one-element list holding the writeShellScript
  # derivation itself (criome.nix's pattern, not persona-router's
  # writeText-plus-CLI-arg pattern) — read the built script's own text to
  # recover the embedded, shell-escaped NOTA record.
  encodeScript = builtins.elemAt serviceConfig.ExecStartPre 0;
  encodeScriptText = builtins.readFile encodeScript;

  guardianEncodeScript = builtins.elemAt guardianConfiguration.config.systemd.services.spirit.serviceConfig.ExecStartPre 0;
  guardianEncodeScriptText = builtins.readFile guardianEncodeScript;

  systemPackageNames = lib.concatStringsSep " " (
    map (
      package: package.pname or package.name or "unnamed"
    ) enabledConfiguration.config.environment.systemPackages
  );
  tmpfiles = lib.concatStringsSep "\n" enabledConfiguration.config.systemd.tmpfiles.rules;
in
pkgs.runCommand "spirit-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool (servicePresent disabledConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent enabledConfiguration))} = true

  test ${lib.escapeShellArg service.description} = 'spirit journal daemon'
  test ${lib.escapeShellArg serviceConfig.User} = spirit
  test ${lib.escapeShellArg serviceConfig.Group} = spirit
  test ${lib.escapeShellArg serviceConfig.UMask} = '0077'
  # Default is owner-only (0077); enabling group access loosens to 0007 so the
  # working socket becomes group-accessible for the co-resident router.
  test ${lib.escapeShellArg groupAccessConfiguration.config.systemd.services.spirit.serviceConfig.UMask} = '0007'
  test ${lib.escapeShellArg (bool serviceConfig.NoNewPrivileges)} = true

  printf '%s' ${lib.escapeShellArg encodeScriptText} | grep -F '/bin/spirit-write-configuration'
  printf '%s' ${lib.escapeShellArg encodeScriptText} | grep -F \
    '(ConfigurationWriteRequest (/run/spirit/spirit.sock (Some /run/spirit/spirit.sock.meta) /var/lib/spirit/spirit.sema None Gating None /run/spirit/spirit-config.rkyv))'
  ! printf '%s' ${lib.escapeShellArg encodeScriptText} | grep -F '""'

  printf '%s' ${lib.escapeShellArg guardianEncodeScriptText} | grep -F \
    '(Some (/run/agent/agent.sock (Some criomos-local) None 60000 None))'

  printf '%s' ${lib.escapeShellArg serviceConfig.ExecStart} | grep -F '/bin/spirit-daemon'
  printf '%s' ${lib.escapeShellArg serviceConfig.ExecStart} | grep -F '/run/spirit/spirit-config.rkyv'

  printf '%s' ${lib.escapeShellArg systemPackageNames} | grep -F spirit
  printf '%s' ${lib.escapeShellArg tmpfiles} | grep -F 'd /var/lib/spirit 0700 spirit spirit -'
  printf '%s' ${lib.escapeShellArg tmpfiles} | grep -F 'd /run/spirit 0755 spirit spirit -'

  touch "$out"
''
