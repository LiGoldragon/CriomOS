{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseBehavesAs = {
    bareMetal = true;
    center = false;
    edge = false;
    iso = false;
    largeAi = false;
    lowPower = false;
    router = false;
  };

  baseNode = {
    behavesAs = baseBehavesAs;
    capabilities = [ ];
    keyboard = "Qwerty";
    size = "Medium";
    machine = {
      kind = "Metal";
      architecture = "x86_64";
      host = null;
      additionalHosts = [ ];
      user = null;
      diskGib = null;
      hardware = {
        cores = 2;
        model = "all-x86-64";
        motherboard = null;
        chipGeneration = null;
        ramGib = 4;
        location = null;
      };
    };
  };

  configurationFor =
    deployment: node:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit deployment inputs;
        horizon = {
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  defaultConfiguration = configurationFor {
    includeHome = true;
  } baseNode;

  homeOffConfiguration = configurationFor {
    includeHome = false;
  } baseNode;

  explicitFirmwareConfiguration = configurationFor {
    includeHome = false;
    includeAllFirmware = true;
  } baseNode;

  explicitSyntheticConfiguration = configurationFor {
    includeHome = true;
    includeAllFirmware = false;
  } baseNode;

  intelT14Configuration =
    configurationFor
      {
        includeHome = true;
      }
      (
        baseNode
        // {
          machine = baseNode.machine // {
            hardware = baseNode.machine.hardware // {
              chipGeneration = 12;
              model = "ThinkPadT14Gen5Intel";
            };
          };
        }
      );
in
pkgs.runCommand "metal-firmware-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool defaultConfiguration.hardware.enableAllFirmware)} = true
  test ${lib.escapeShellArg (bool homeOffConfiguration.hardware.enableAllFirmware)} = false
  test ${lib.escapeShellArg (bool explicitFirmwareConfiguration.hardware.enableAllFirmware)} = true
  test ${lib.escapeShellArg (bool explicitSyntheticConfiguration.hardware.enableAllFirmware)} = false
  test ${lib.escapeShellArg (bool (builtins.elem "i915" intelT14Configuration.boot.kernelModules))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "xe" intelT14Configuration.boot.kernelModules))} = false
  ! printf '%s' ${lib.escapeShellArg intelT14Configuration.boot.extraModprobeConfig} | grep -F 'blacklist i915'
  ! printf '%s' ${lib.escapeShellArg intelT14Configuration.boot.extraModprobeConfig} | grep -F 'force_probe=7d45'

  touch "$out"
''
