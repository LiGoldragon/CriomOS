{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkOverride optionals;
  inherit (horizon) node exNodes;
  inherit (builtins)
    head
    match
    split
    ;

  sanitizeIp =
    ip:
    if ip == null || ip == "" then
      null
    else
      let
        cleaned = head (split "/" ip);
      in
      if cleaned == "" || match ".*%.*" cleaned != null then null else cleaned;

  mkCriomeHostEntries =
    name: node:
    let
      inherit (node) criomeDomainName;
      inherit (node) isNixCache nixCacheDomain;
      nodeIp = sanitizeIp node.nodeIp;
      yggAddress = sanitizeIp node.yggAddress;
      linkLocalIps = builtins.filter (ip: ip != null) (builtins.map sanitizeIp node.linkLocalIps);
      nixCacheAliases = optionals (isNixCache && nixCacheDomain != null && nixCacheDomain != "") [
        nixCacheDomain
      ];

      mkPreNodeHost = linkLocalIP: [ ("wg." + criomeDomainName) ];

      nodeHost = {
        "${nodeIp}" = [ criomeDomainName ];
      };

      preNodeHosts = lib.genAttrs linkLocalIps mkPreNodeHost;

      nodeHosts = lib.optionalAttrs (nodeIp != null) (nodeHost // preNodeHosts);

      yggdrasilHost = lib.optionalAttrs (yggAddress != null) {
        "${yggAddress}" = [ criomeDomainName ] ++ nixCacheAliases;
      };

    in
    yggdrasilHost // nodeHosts;

  allNodes = {
    "${node.name}" = node;
  }
  // exNodes;
in
{
  imports = [
    ./dnsmasq.nix
    ./yggdrasil.nix
    ./tailscale.nix
    ./headscale.nix
    ./nordvpn.nix
    ./wifi-eap.nix
    ./networkd.nix
    ./wireguard.nix
    ./resolver.nix
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
    hosts = lib.concatMapAttrs mkCriomeHostEntries allNodes;
  };

  services = {
    nscd.enable = false;
  };

  system.nssModules = mkOverride 0 [ ];
}
