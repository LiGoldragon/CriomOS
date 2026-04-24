{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkOverride optional optionals;
  inherit (horizon) node exNodes;

  mkCriomeHostEntries =
    name: node:
    let
      inherit (node) criomeDomainName nodeIp yggAddress;
      inherit (node) isNixCache nixCacheDomain;

      mkPreNodeHost = linkLocalIP: [ ("wg." + criomeDomainName) ];

      nodeHost = {
        "${nodeIp}" = [ criomeDomainName ];
      };

      preNodeHosts = lib.genAttrs node.linkLocalIps mkPreNodeHost;

      nodeHosts = lib.optionalAttrs (nodeIp != null) (nodeHost // preNodeHosts);

      yggdrasilHost = lib.optionalAttrs (yggAddress != null) {
        "${yggAddress}" = [ criomeDomainName ] ++ (optional isNixCache nixCacheDomain);
      };

    in
    yggdrasilHost // nodeHosts;

in
{
  imports = [
    ./unbound.nix
    ./yggdrasil.nix
    ./tailscale.nix
    ./headscale.nix
    ./nordvpn.nix
    ./wifi-eap.nix
    ./networkd.nix
    ./wireguard.nix
  ];

  networking = {
    hostName = node.name;
    dhcpcd.extraConfig = "noipv4ll";
    nameservers = [
      "::1"
      "127.0.0.1"
      "1.1.1.1"
      "9.9.9.9"
    ];
    hosts = lib.concatMapAttrs mkCriomeHostEntries exNodes;
  };

  services = {
    nscd.enable = false;
  };

  system.nssModules = mkOverride 0 [ ];
}
