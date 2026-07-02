{
  inputs,
  pkgs,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  size = {
    min = true;
    medium = true;
    large = false;
    max = false;
  };

  edgeConfiguration =
    (lib.nixosSystem {
      inherit pkgs;
      specialArgs = {
        horizon = {
          node = {
            inherit size;
            behavesAs.edge = true;
          };
        };
      };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/edge/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  normalizeConfiguration =
    (lib.nixosSystem {
      inherit pkgs;
      specialArgs = {
        horizon = {
          exNodes = { };
          node = {
            inherit size;
            useColemak = true;
            behavesAs.iso = false;
            hasVideoOutput = true;
            enableNetworkManager = false;
          };
        };
      };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/normalize.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  metalConfiguration =
    (lib.nixosSystem {
      inherit pkgs;
      specialArgs = {
        inherit inputs;
        horizon = {
          node = {
            inherit size;
            useColemak = true;
            behavesAs = {
              bareMetal = true;
              center = false;
              edge = true;
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
            wantsHwVideoAccel = false;
            wantsPrinting = false;
          };
        };
      };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  laptopKeydConfiguration = edgeConfiguration.services.keyd.keyboards.laptop.extraConfig;
  generatedLaptopKeydConfiguration = edgeConfiguration.environment.etc."keyd/laptop.conf".text;
  sessionVariables = normalizeConfiguration.environment.sessionVariables;
in
assert lib.assertMsg (edgeConfiguration.services.keyd.enable
) "edge hosts must enable keyd for laptop-local physical key mapping";
assert lib.assertMsg (
  edgeConfiguration.services.keyd.keyboards.laptop.ids == [ "0001:0001" ]
) "laptop keyd config must target only the AT Translated Set 2 keyboard id";
assert lib.assertMsg (lib.hasInfix
  ''
    [ids]
    0001:0001
  ''
  generatedLaptopKeydConfiguration
) "generated laptop keyd config must target only the AT Translated Set 2 keyboard id";
assert lib.assertMsg (lib.hasInfix "[colemak:layout]" laptopKeydConfiguration)
  "laptop keyd config must use keyd's shipped Colemak layout";
assert lib.assertMsg (lib.hasInfix "[colemak:layout]" generatedLaptopKeydConfiguration)
  "generated laptop keyd config must inline keyd's shipped Colemak layout";
assert lib.assertMsg (lib.hasInfix "default_layout = colemak" laptopKeydConfiguration)
  "laptop keyd config must select Colemak through keyd default_layout";
assert lib.assertMsg (lib.hasInfix "default_layout = colemak" generatedLaptopKeydConfiguration)
  "generated laptop keyd config must select Colemak through keyd default_layout";
assert lib.assertMsg (
  lib.hasInfix "leftalt = layer(meta)" laptopKeydConfiguration
  && lib.hasInfix "leftmeta = layer(alt)" laptopKeydConfiguration
) "laptop keyd config must preserve the existing left Alt/Meta swap";
assert lib.assertMsg (
  lib.hasInfix "leftalt = layer(meta)" generatedLaptopKeydConfiguration
  && lib.hasInfix "leftmeta = layer(alt)" generatedLaptopKeydConfiguration
) "generated laptop keyd config must preserve the existing left Alt/Meta swap";
assert lib.assertMsg (
  sessionVariables.XKB_DEFAULT_LAYOUT == "us" && sessionVariables.XKB_DEFAULT_VARIANT == ""
) "global XKB defaults must stay plain US without a Colemak variant";
assert lib.assertMsg (
  metalConfiguration.services.xserver.xkb.variant == ""
) "X11 XKB must not apply a global Colemak variant";

pkgs.runCommand "laptop-keyboard-keyd-check" { } ''
  touch "$out"
''
