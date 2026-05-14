{
  lib,
  horizon,
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
      or (throw "network: horizon.cluster.resolver is required (system nameservers come from horizon)");

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
      # Step 14: yggdrasil presence is now a typed sub-record
      # `node.yggdrasil = { pub_key, address, subnet }` (or null).
      # No more `node.yggAddress` sibling field.
      yggAddress =
        if node.yggdrasil == null then null else sanitizeIp node.yggdrasil.address;
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
    # Local listens first (loopback, LAN gateway via dnsmasq if router),
    # then upstreams + fallbacks. Whole list comes from horizon —
    # no Cloudflare/Quad9 literal in this file.
    nameservers =
      clusterResolver.listens ++ clusterResolver.upstreams ++ clusterResolver.fallbacks;
    hosts = lib.concatMapAttrs mkCriomeHostEntries allNodes;
  };

  services = {
    nscd.enable = false;
  };

  system.nssModules = mkOverride 0 [ ];
}
