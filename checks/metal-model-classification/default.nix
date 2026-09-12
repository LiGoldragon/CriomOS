# What `modules/nixos/metal/default.nix` decides from the Horizon projection
# alone, now that horizon-rs no longer decides it for us.
#
# Three behaviours are at stake, and each was silently lost or silently wrong
# before: a ThinkPad's battery/thermal handling (which an `or false` default
# would have switched off estate-wide), the lid-switch policy horizon-rs
# retired along with the hardware flags, and the refusal to guess when the
# projection names a machine this system does not classify.
{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  horizonNode = import ../../fixtures/horizon-node.nix { inherit lib; };

  configurationFor =
    overrides:
    (lib.nixosSystem {
      inherit pkgs;
      specialArgs = {
        inherit inputs;
        deployment = {
          includeHome = true;
          includeAllFirmware = true;
        };
        horizon.node = horizonNode.node overrides;
      };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  thinkpad = configurationFor {
    behavesAs.edge = true;
    machine.hardware = {
      model = "ThinkPadT14Gen5Intel";
      chipGeneration = 12;
    };
  };

  generic = configurationFor {
    behavesAs.edge = true;
    machine.hardware.model = "all-x86-64";
  };

  center = configurationFor {
    behavesAs.center = true;
    machine.hardware.model = "GMKtec EVO-X2";
  };

  lowPowerEdge = configurationFor {
    behavesAs = {
      center = false;
      edge = true;
      lowPower = true;
    };
    machine.hardware.model = "rpi3B";
  };

  # `builtins.tryEval` forces the value and reports whether forcing threw. A
  # `throw` from the model table is what must reach it — not a `false`.
  unclassified = builtins.tryEval (
    lib.deepSeq (configurationFor { machine.hardware.model = "AcmeLaptop9000"; }).services.thinkfan
      "forced"
  );

  modelless = builtins.tryEval (
    lib.deepSeq (configurationFor { machine.hardware.model = null; }).services.thinkfan "forced"
  );
in
assert lib.assertMsg thinkpad.services.thinkfan.enable
  "a ThinkPad projection must keep user-space fan control enabled";
assert lib.assertMsg (
  thinkpad.systemd.services ? battery-charge-default
) "a ThinkPad projection must keep the battery charge-threshold service";
assert lib.assertMsg thinkpad.hardware.cpu.intel.updateMicrocode
  "an Intel ThinkPad projection must keep Intel microcode updates";
assert lib.assertMsg (builtins.any (
  package: lib.getName package == "battery-ctl"
) thinkpad.environment.systemPackages) "a ThinkPad projection must ship battery-ctl";
assert lib.assertMsg (
  thinkpad.users.groups ? power
) "a ThinkPad projection must keep the power group that battery-ctl is granted through";

assert lib.assertMsg (
  !generic.services.thinkfan.enable
) "a generic x86-64 projection must not enable ThinkPad fan control";
assert lib.assertMsg (
  !(generic.systemd.services ? battery-charge-default)
) "a generic x86-64 projection must not define ThinkPad battery thresholds";
assert lib.assertMsg (
  !generic.hardware.cpu.intel.updateMicrocode
) "a generic x86-64 projection must not claim an Intel chip";

assert lib.assertMsg (
  center.services.logind.settings.Login.HandleLidSwitch == "ignore"
) "a center node must ignore its lid on battery";
assert lib.assertMsg (
  center.services.logind.settings.Login.HandleLidSwitchExternalPower == "ignore"
) "a center node must ignore its lid on external power";
assert lib.assertMsg (
  center.services.logind.settings.Login.HandleLidSwitchDocked == "ignore"
) "a non-edge node must ignore its lid when docked";

assert lib.assertMsg (
  lowPowerEdge.services.logind.settings.Login.HandleLidSwitch == "suspend"
) "a non-center node must suspend on lid close on battery";
assert lib.assertMsg (
  lowPowerEdge.services.logind.settings.Login.HandleLidSwitchExternalPower == "suspend"
) "a low-power node must suspend on lid close even on external power";
assert lib.assertMsg (
  lowPowerEdge.services.logind.settings.Login.HandleLidSwitchDocked == "lock"
) "an edge node must lock rather than suspend when docked";
assert lib.assertMsg (builtins.elem "cma=32M" lowPowerEdge.boot.kernelParams)
  "an rpi3B projection must keep its Raspberry Pi kernel parameters";
assert lib.assertMsg (
  !(builtins.elem "cma=32M" generic.boot.kernelParams)
) "a non-rpi3B projection must not carry Raspberry Pi kernel parameters";

assert lib.assertMsg (
  !unclassified.success
) "a machine model this system does not classify must refuse to evaluate, not default to false";
assert lib.assertMsg (
  !modelless.success
) "a bare-metal projection with no model must refuse to evaluate, not default to false";

pkgs.runCommand "metal-model-classification" { } ''
  touch "$out"
''
