{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkForce mkIf;
  inherit (horizon.node) behavesAs enableNetworkManager;

  networkManagerDesktop = enableNetworkManager && !behavesAs.router;
in
{
  config = mkIf networkManagerDesktop {
    networking = {
      nameservers = mkForce [ ];
      networkmanager.dns = "systemd-resolved";
      resolvconf.enable = mkForce false;
    };

    services.resolved = {
      enable = true;
      settings.Resolve.FallbackDNS = [
        "1.1.1.1"
        "9.9.9.9"
      ];
    };
  };
}
