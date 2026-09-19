{
  config,
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:

let
  cfg = config.criomos.testing.opencode;
  nodeServices = import ../node-services.nix { inherit lib; };
  enabled = nodeServices.has horizon.node.capabilities "openCodeTesting";
  secretName = "opencodeServerPassword";
  secretAvailable = inputs.secrets.sopsFiles ? ${secretName};
in
{
  options.criomos.testing.opencode.enable = lib.mkEnableOption "OpenCode CLI for testing";

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ pkgs.opencode ];
    })
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = secretAvailable;
          message = "OpenCode testing requires inputs.secrets.sopsFiles.${secretName}";
        }
      ];
      criomos.testing.opencode.enable = true;
      sops.secrets.${secretName} = {
        format = "binary";
        sopsFile = inputs.secrets.sopsFiles.${secretName};
        owner = "li";
        mode = "0400";
      };
    })
  ];
}
