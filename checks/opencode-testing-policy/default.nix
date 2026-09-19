{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  configurationFor =
    settings:
    lib.nixosSystem {
      inherit pkgs;
      modules = [
        ../../modules/nixos/testing/opencode.nix
        { system.stateVersion = "26.05"; }
        settings
      ];
    };

  packagesFor = settings: (configurationFor settings).config.environment.systemPackages;
  hasOpenCode = settings: lib.elem pkgs.opencode (packagesFor settings);
in
assert lib.assertMsg (!(hasOpenCode { })) "OpenCode testing must be disabled by default";
assert lib.assertMsg (hasOpenCode {
  criomos.testing.opencode.enable = true;
}) "Enabling OpenCode testing must install pkgs.opencode";
pkgs.runCommand "opencode-testing-policy" { } ''
  touch "$out"
''
