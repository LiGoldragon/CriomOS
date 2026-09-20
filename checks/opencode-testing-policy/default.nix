{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  configurationFor = settings:
    lib.nixosSystem {
      inherit pkgs;
      modules = [
        ../../modules/nixos/testing/opencode.nix
        {
          options.sops.secrets = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options.path = lib.mkOption {
                  type = lib.types.str;
                  default = "/run/secrets/opencodeServerPassword";
                };
              }
            );
            default = { };
          };
        }
        { system.stateVersion = "26.05"; }
        settings
      ];
    };

  packagesFor = settings: (configurationFor settings).config.environment.systemPackages;
  hasOpenCode = settings: lib.elem pkgs.opencode (packagesFor settings);
  serviceFor = settings: (configurationFor settings).config.systemd.user.services.opencode;
  enabledSettings = {
    horizon.node = {
      capabilities = [ { kind = "openCodeTesting"; } ];
      keys.yggdrasil.address = "201:6de1:5500:7cac:2db9:759e:42d2:fb1d";
    };
    inputs.secrets.sopsFiles.opencodeServerPassword = "/dev/null";
  };
in
assert lib.assertMsg (!(hasOpenCode { })) "OpenCode testing must be disabled by default";
assert lib.assertMsg (hasOpenCode {
  criomos.testing.opencode.enable = true;
}) "Enabling OpenCode testing must install pkgs.opencode";
assert lib.assertMsg (hasOpenCode enabledSettings) "OpenCode capability must install pkgs.opencode";
assert lib.assertMsg (serviceFor enabledSettings).environment.OPENCODE_CONFIG_CONTENT == ''{"share":"disabled"}'' "OpenCode server must disable sharing without replacing user configuration";
assert lib.assertMsg (serviceFor enabledSettings).serviceConfig.LoadCredential == [ "opencode-server-password:/run/secrets/opencodeServerPassword" ] "OpenCode server must receive its password through LoadCredential";
assert lib.assertMsg (serviceFor enabledSettings).serviceConfig.ExecStart.text != "" "OpenCode server must have an execution contract";
pkgs.runCommand "opencode-testing-policy" { } ''
  touch "$out"
''
