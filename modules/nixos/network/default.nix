{
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (lib) mkOverride optionals;
  inherit (horizon) cluster node exNodes;
  inherit (builtins)
    head
    match
    split
    ;

  clusterResolver =
    cluster.resolver
      or (throw "network: horizon.cluster.resolver is required (local listen addresses come from horizon)");
  resolverDefaults = constants.network.resolver;

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
      nodeIp = sanitizeIp node.nodeIp;
      # Step 14: yggdrasil presence is now a typed sub-record
      # `node.yggdrasil = { pub_key, address, subnet }` (or null).
      # No more `node.yggAddress` sibling field.
      yggAddress =
        if node.yggdrasil == null then null else sanitizeIp node.yggdrasil.address;
      linkLocalIps = builtins.filter (ip: ip != null) (builtins.map sanitizeIp node.linkLocalIps);
      # Step 7a: nixCache is a typed sub-record (domain + url) or null.
      # Replaces the old (isNixCache, nixCacheDomain, nixUrl) trio.
      nixCacheAliases = optionals (node.nixCache != null) [
        node.nixCache.domain
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
    # Local listens first (loopback, LAN gateway via dnsmasq if router),
    # then CriomOS-owned upstreams + fallbacks.
    nameservers =
      clusterResolver.listens ++ resolverDefaults.upstreams ++ resolverDefaults.fallbacks;
    hosts = lib.concatMapAttrs mkCriomeHostEntries allNodes;
  };

  services = {
    nscd.enable = false;
  };

  system.nssModules = mkOverride 0 [ ];
}
