{
  inputs,
  pkgs,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  desktopSystem = lib.nixosSystem {
    inherit pkgs;
    specialArgs = {
      horizon = {
        exNodes = { };
        node = {
          size.min = false;
          useColemak = false;
          behavesAs.iso = false;
          hasVideoOutput = true;
          enableNetworkManager = false;
        };
      };
    };
    modules = [
      inputs.nixpkgs.nixosModules.readOnlyPkgs
      ../../modules/nixos/normalize.nix
    ];
  };

  policy = desktopSystem.config.services.pipewire.wireplumber.extraConfig."10-criomos-desktop-audio";
  bluetoothPolicy = policy."monitor.bluez.properties";
  loopbackRules = policy."monitor.alsa.rules";
  loopbackMatches = builtins.concatMap (rule: rule.matches or [ ]) loopbackRules;
  loopbackMatchNames = map (match: match."node.name" or "") loopbackMatches;
  loopbackActions = builtins.concatMap (rule: [ (rule.actions.update-props or { }) ]) loopbackRules;
in
assert lib.assertMsg (lib.all (role: builtins.elem role bluetoothPolicy."bluez5.roles") [
  "hsp_ag"
  "hfp_ag"
]) "desktop Bluetooth policy must register audio-gateway HSP/HFP roles for microphone peripherals";
assert lib.assertMsg (
  !(builtins.elem "hsp_hs" bluetoothPolicy."bluez5.roles")
) "desktop Bluetooth policy must not advertise the host as an HSP headset";
assert lib.assertMsg (
  !(builtins.elem "hfp_hf" bluetoothPolicy."bluez5.roles")
) "desktop Bluetooth policy must not advertise the host as an HFP hands-free device";
assert lib.assertMsg (
  bluetoothPolicy."bluez5.hfphsp-backend" == "native"
) "desktop Bluetooth policy must use PipeWire's native HFP/HSP backend";
assert lib.assertMsg (builtins.elem "~alsa_output.platform-snd_aloop.*" loopbackMatchNames)
  "desktop audio policy must match ALSA loopback output nodes";
assert lib.assertMsg (builtins.elem "~alsa_input.platform-snd_aloop.*" loopbackMatchNames)
  "desktop audio policy must match ALSA loopback input nodes";
assert lib.assertMsg (lib.any (
  action: (action."priority.driver" or null) == 1 && (action."priority.session" or null) == 1
) loopbackActions) "desktop audio policy must demote ALSA loopback nodes in PipeWire";
assert lib.assertMsg (lib.all (
  action: !(action."node.disabled" or false)
) loopbackActions) "desktop audio policy must leave ALSA loopback nodes selectable";

pkgs.runCommand "desktop-audio-policy-check" { } ''
  touch "$out"
''
