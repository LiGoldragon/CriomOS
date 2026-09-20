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
  yggdrasilAddress =
    if horizon.node.keys.yggdrasil == null then
      null
    else
      lib.head (lib.splitString "/" horizon.node.keys.yggdrasil.address);
  serverConfig = builtins.toJSON { share = "disabled"; };
  serve = pkgs.writeShellScript "opencode-serve" ''
    set -euo pipefail
    IFS= read -r OPENCODE_SERVER_PASSWORD < "$CREDENTIALS_DIRECTORY/opencode-server-password"
    export OPENCODE_SERVER_PASSWORD
    exec ${pkgs.opencode}/bin/opencode serve --hostname ${yggdrasilAddress} --port 4096
  '';
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
        {
          assertion = yggdrasilAddress != null;
          message = "OpenCode testing requires the node's Yggdrasil address";
        }
      ];
      criomos.testing.opencode.enable = true;
      sops.secrets.${secretName} = {
        format = "binary";
        sopsFile = inputs.secrets.sopsFiles.${secretName};
        owner = "li";
        mode = "0400";
      };
      systemd.user.services.opencode = {
        description = "OpenCode server";
        wantedBy = [ "default.target" ];
        environment.OPENCODE_CONFIG_CONTENT = serverConfig;
        serviceConfig = {
          LoadCredential = [ "opencode-server-password:${config.sops.secrets.${secretName}.path}" ];
          ExecStart = serve;
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    })
  ];
}
