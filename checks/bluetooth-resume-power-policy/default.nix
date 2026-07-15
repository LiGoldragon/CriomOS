{
  inputs,
  pkgs,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  edgeSystem = lib.nixosSystem {
    inherit pkgs;
    specialArgs = {
      horizon = {
        node = {
          size = {
            min = true;
            medium = false;
            large = false;
            max = false;
          };
          behavesAs = {
            edge = true;
            iso = false;
          };
        };
      };
    };
    modules = [
      inputs.nixpkgs.nixosModules.readOnlyPkgs
      ../../modules/nixos/edge/default.nix
    ];
  };

  resumePower = edgeSystem.config.systemd.services.bluetooth-resume-power;
in
assert lib.assertMsg edgeSystem.config.hardware.bluetooth.powerOnBoot
  "edge Bluetooth must retain BlueZ boot and hotplug power policy";
assert lib.assertMsg (builtins.elem "suspend.target" resumePower.wantedBy)
  "Bluetooth resume power restoration must run for the suspend target";
assert lib.assertMsg (builtins.elem "systemd-suspend.service" resumePower.after)
  "Bluetooth resume power restoration must wait for systemd-suspend";
assert lib.assertMsg (builtins.elem "bluetooth.service" resumePower.after)
  "Bluetooth resume power restoration must wait for BlueZ";
assert lib.assertMsg (builtins.elem "bluetooth.service" resumePower.requires)
  "Bluetooth resume power restoration must require BlueZ";
assert lib.assertMsg (
  resumePower.serviceConfig.Type == "oneshot"
) "Bluetooth resume power restoration must be a one-shot action";
assert lib.assertMsg (
  !(resumePower.serviceConfig.RemainAfterExit or false)
) "Bluetooth resume power restoration must run after every resume";
assert lib.assertMsg (
  resumePower.serviceConfig.ExecStart == "${pkgs.bluez}/bin/bluetoothctl --timeout 10 power on"
) "Bluetooth resume power restoration must make one bounded idempotent BlueZ request";
assert lib.assertMsg (
  !edgeSystem.config.services.blueman.enable
) "edge Bluetooth ownership must not regress to Blueman";
assert lib.assertMsg edgeSystem.config.services.gnome.gnome-settings-daemon.enable
  "edge Bluetooth must retain GNOME rfkill integration";

pkgs.runCommand "bluetooth-resume-power-policy-check" { } ''
  touch "$out"
''
