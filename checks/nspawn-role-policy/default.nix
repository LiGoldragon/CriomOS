{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseSize = {
    large = false;
  };

  baseBehavesAs = {
    center = false;
    iso = false;
  };

  baseNode = {
    buildCores = 2;
    cacheUrls = [ ];
    size = baseSize;
    behavesAs = baseBehavesAs;
  };

  largeCenterNode = {
    buildCores = 8;
    cacheUrls = [ ];
    size = {
      large = true;
    };
    behavesAs = {
      center = true;
      iso = false;
    };
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          cluster.trustedBuildPubKeys = [ ];
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/nix/client.nix
        ../../modules/nixos/nspawn.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  packageNamesFor = configuration: map lib.getName configuration.config.environment.systemPackages;

  baseConfiguration = configurationFor baseNode;
  serviceConfiguration = configurationFor largeCenterNode;
  servicePackageNames = packageNamesFor serviceConfiguration;
  servicePackage =
    lib.findFirst (package: lib.getName package == "criomos-nspawn")
      (throw "criomos-nspawn package missing from large center configuration")
      serviceConfiguration.config.environment.systemPackages;

  basePackageEnabled = builtins.elem "criomos-nspawn" (packageNamesFor baseConfiguration);
  servicePackageEnabled = builtins.elem "criomos-nspawn" servicePackageNames;
  baseContainersEnabled = baseConfiguration.config.boot.enableContainers;
  serviceContainersEnabled = serviceConfiguration.config.boot.enableContainers;
  serviceTemplateEnabled = builtins.hasAttr "container@" serviceConfiguration.config.systemd.services;
  serviceNixosContainerEnabled = builtins.elem "nixos-container" servicePackageNames;
  serviceSudoConfig = serviceConfiguration.config.security.sudo.configFile;
  serviceMachinedWantedBy =
    serviceConfiguration.config.systemd.services.systemd-machined.wantedBy or [ ];
in
pkgs.runCommand "nspawn-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool basePackageEnabled)} = false
  test ${lib.escapeShellArg (bool servicePackageEnabled)} = true
  test ${lib.escapeShellArg (bool baseContainersEnabled)} = false
  test ${lib.escapeShellArg (bool serviceContainersEnabled)} = true
  test ${lib.escapeShellArg (bool serviceTemplateEnabled)} = true
  test ${lib.escapeShellArg (bool serviceNixosContainerEnabled)} = true
  test ${lib.escapeShellArg (bool (builtins.elem "multi-user.target" serviceMachinedWantedBy))} = true

  printf '%s' ${lib.escapeShellArg serviceSudoConfig} | grep -F '%nixdev'
  printf '%s' ${lib.escapeShellArg serviceSudoConfig} | grep -F 'NOPASSWD'
  printf '%s' ${lib.escapeShellArg serviceSudoConfig} | grep -F '/run/current-system/sw/bin/criomos-nspawn'

  ${servicePackage}/bin/criomos-nspawn help >/dev/null
  grep -F '/run/wrappers/bin/sudo' ${servicePackage}/bin/criomos-nspawn

  touch "$out"
''
