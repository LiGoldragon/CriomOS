{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkIf optionalAttrs optionals;
  isNixCache = horizon.node.nixCache != null;
in
{
  networking.firewall.allowedTCPPorts = optionals isNixCache [
    80
  ];

  users = {
    groups = optionalAttrs isNixCache {
      nix-serve = {
        gid = 199;
      };
    };

    users = optionalAttrs isNixCache {
      nix-serve = {
        uid = 199;
        group = "nix-serve";
      };
    };
  };

  services.nix-serve = {
    enable = isNixCache;
    bindAddress = "";
    port = 80;
    secretKeyFile = "/var/lib/nix-serve/nix-secret-key";
  };

  systemd.services.nix-serve.serviceConfig = mkIf isNixCache {
    AmbientCapabilities = "CAP_NET_BIND_SERVICE";
    CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
  };
}
