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
    deployment:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit deployment inputs;
        horizon = {
          node = baseNode;
        };
      };
      modules = [
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  defaultConfiguration = configurationFor {
    includeHome = true;
  };

  homeOffConfiguration = configurationFor {
    includeHome = false;
  };

  explicitFirmwareConfiguration = configurationFor {
    includeHome = false;
    includeAllFirmware = true;
  };

  explicitSyntheticConfiguration = configurationFor {
    includeHome = true;
    includeAllFirmware = false;
  };
in
pkgs.runCommand "metal-firmware-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool defaultConfiguration.hardware.enableAllFirmware)} = true
  test ${lib.escapeShellArg (bool homeOffConfiguration.hardware.enableAllFirmware)} = false
  test ${lib.escapeShellArg (bool explicitFirmwareConfiguration.hardware.enableAllFirmware)} = true
  test ${lib.escapeShellArg (bool explicitSyntheticConfiguration.hardware.enableAllFirmware)} = false

  touch "$out"
''
