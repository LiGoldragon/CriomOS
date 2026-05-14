{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkForce mkIf;
  inherit (horizon) cluster;
  inherit (horizon.node) behavesAs enableNetworkManager;

  networkManagerDesktop = enableNetworkManager && !behavesAs.router;

  clusterResolver =
    cluster.resolver
      or (throw "resolver: horizon.cluster.resolver is required (FallbackDNS comes from horizon)");
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
      settings.Resolve.FallbackDNS = clusterResolver.fallbacks;
    };
  };
}
