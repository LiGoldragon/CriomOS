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
    router = false;
  };

  baseSize = {
    min = false;
    medium = true;
    large = false;
    max = false;
  };

  baseNode = {
    behavesAs = baseBehavesAs;
    chipIsIntel = false;
    computerIs.rpi3b = false;
    handleLidSwitch = "ignore";
    handleLidSwitchDocked = "ignore";
    handleLidSwitchExternalPower = "ignore";
    machine = {
      chipGen = null;
      model = "all-x86-64";
    };
    modelIsThinkpad = false;
    size = baseSize;
    useColemak = false;
    wantsHwVideoAccel = false;
    wantsPrinting = false;
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
          chipIsIntel = true;
          modelIsThinkpad = true;
          machine = {
            chipGen = 12;
            model = "ThinkPadT14Gen5Intel";
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
