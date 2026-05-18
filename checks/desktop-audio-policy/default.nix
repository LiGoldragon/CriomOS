{ pkgs, ... }:

let
  inherit (pkgs) lib;
  normalizeModule = builtins.readFile ../../modules/nixos/normalize.nix;
in
assert lib.assertMsg (
  lib.hasInfix "hsp_hs hsp_ag hfp_hf hfp_ag" normalizeModule
) "desktop Bluetooth policy must register HSP/HFP roles for microphone-only devices";
assert lib.assertMsg (
  lib.hasInfix ''bluez5.hfphsp-backend = "native"'' normalizeModule
) "desktop Bluetooth policy must use PipeWire's native HFP/HSP backend";
assert lib.assertMsg (
  lib.hasInfix "node.name = \"~alsa_output.platform-snd_aloop.*\"" normalizeModule
) "desktop audio policy must match ALSA loopback output nodes";
assert lib.assertMsg (
  lib.hasInfix "node.disabled = true" normalizeModule
) "desktop audio policy must disable ALSA loopback nodes in PipeWire";

pkgs.runCommand "desktop-audio-policy-check" { } ''
  touch "$out"
''
