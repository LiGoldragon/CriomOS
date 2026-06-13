{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseNode = {
    services = [ ];
  };

  personaOnlyNode = {
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

  mirrorNode = {
    services = [
      { TailnetClient = { }; }
      {
        PersonaDevelopment = {
          capabilities = [
            { GitoliteServer = { }; }
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
        ../../modules/nixos/mirror.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  baseConfiguration = configurationFor baseNode;
  personaOnlyConfiguration = configurationFor personaOnlyNode;
  mirrorConfiguration = configurationFor mirrorNode;

  servicePresent = configuration: builtins.hasAttr "mirror" configuration.config.systemd.services;
  mirrorService = mirrorConfiguration.config.systemd.services.mirror;
  mirrorServiceConfig = mirrorService.serviceConfig;
  execStartPreParts = lib.splitString " " mirrorServiceConfig.ExecStartPre;
  daemonConfigurationNota = builtins.readFile (builtins.elemAt execStartPreParts 1);
  mirrorSystemPackageNames = lib.concatStringsSep " " (
    map (
      package: package.pname or package.name or "unnamed"
    ) mirrorConfiguration.config.environment.systemPackages
  );
  tmpfiles = lib.concatStringsSep "\n" mirrorConfiguration.config.systemd.tmpfiles.rules;
  tailscaleTcpPorts =
    mirrorConfiguration.config.networking.firewall.interfaces.tailscale0.allowedTCPPorts or [ ];
in
pkgs.runCommand "mirror-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool (servicePresent baseConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent personaOnlyConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent mirrorConfiguration))} = true

  test ${lib.escapeShellArg mirrorService.description} = 'SEMA version-control mirror daemon'
  test ${lib.escapeShellArg mirrorServiceConfig.User} = mirror
  test ${lib.escapeShellArg mirrorServiceConfig.Group} = nixdev
  printf '%s' ${lib.escapeShellArg (builtins.toJSON mirrorServiceConfig.SupplementaryGroups)} | grep -F mirror
  printf '%s' ${lib.escapeShellArg mirrorServiceConfig.ExecStartPre} | grep -F '/bin/mirror-write-configuration'
  printf '%s' ${lib.escapeShellArg mirrorServiceConfig.ExecStartPre} | grep -F 'mirror-daemon-configuration.nota'
  printf '%s' ${lib.escapeShellArg mirrorServiceConfig.ExecStart} | grep -F '/bin/mirror-daemon'
  printf '%s' ${lib.escapeShellArg mirrorServiceConfig.ExecStart} | grep -F '/run/mirror/mirror-daemon.rkyv'
  printf '%s' ${lib.escapeShellArg daemonConfigurationNota} | grep -F '(/run/mirror/mirror-daemon.rkyv (/var/lib/mirror/mirror.sema /run/mirror/working.sock 432 /run/mirror/meta.sock 384 0.0.0.0:7474))'
  ! printf '%s' ${lib.escapeShellArg daemonConfigurationNota} | grep -F '"'

  printf '%s' ${lib.escapeShellArg mirrorSystemPackageNames} | grep -F mirror
  printf '%s' ${lib.escapeShellArg tmpfiles} | grep -F 'd /var/lib/mirror 2770 mirror mirror -'
  printf '%s' ${lib.escapeShellArg tmpfiles} | grep -F 'd /run/mirror 0755 mirror nixdev -'
  printf '%s' ${lib.escapeShellArg (builtins.toJSON tailscaleTcpPorts)} | grep -F 7474

  touch "$out"
''
