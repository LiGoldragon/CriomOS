{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  keyboardUaccessRule = ''SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="uaccess"'';

  configuration =
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          node = {
            behavesAs = {
              bareMetal = true;
              center = false;
              edge = false;
              iso = false;
              largeAi = false;
              router = false;
            };
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
            size = {
              min = false;
              medium = true;
              large = false;
              max = false;
            };
            useColemak = false;
            wantsHwVideoAccel = false;
            wantsPrinting = false;
          };
        };
      };
      modules = [
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  renderedRules = configuration.services.udev.extraRules;
in
assert lib.assertMsg (lib.hasInfix keyboardUaccessRule renderedRules)
  "keyboard event nodes must receive the uaccess tag in the rendered udev rules";
assert lib.assertMsg (
  !lib.hasInfix ''SUBSYSTEM=="input", KERNEL=="event*", TAG+="uaccess"'' renderedRules
) "input access must remain scoped to ID_INPUT_KEYBOARD devices";
assert lib.assertMsg (
  !lib.hasInfix ''SUBSYSTEM=="input", KERNEL=="event*", GROUP="input"'' renderedRules
) "keyboard capture must not use broad input-group authorization";
pkgs.runCommand "wispr-keyboard-uaccess-check" { } ''
  touch "$out"
''
