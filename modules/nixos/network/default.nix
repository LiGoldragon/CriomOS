{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkOverride optionals;
  inherit (horizon) node;
  exNodes = horizon.exNodes or { };
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
    nodeName: entryNode:
    let
      inherit (entryNode) criomeDomainName;
      isNixCache = entryNode.isNixCache or ((entryNode.nixCache or null) != null);
      nixCacheDomain = entryNode.nixCacheDomain or (entryNode.nixCache.domain or null);
      nodeIp = sanitizeIp (entryNode.nodeIp or null);
      yggAddress = sanitizeIp (entryNode.yggAddress or (entryNode.yggdrasil.address or null));
      linkLocalIps = builtins.filter (ip: ip != null) (builtins.map sanitizeIp (entryNode.linkLocalIps or [ ]));
      nixCacheAliases = optionals (isNixCache && nixCacheDomain != null && nixCacheDomain != "") [
        nixCacheDomain
      ];
      primaryAliases = [ criomeDomainName ] ++ nixCacheAliases;

      mkPreNodeHost = linkLocalIP: [ ("wg." + criomeDomainName) ];

      nodeAliases =
        if yggAddress == null then
          primaryAliases
        else
          [ ("wg." + criomeDomainName) ];

      nodeHost = lib.optionalAttrs (nodeIp != null && nodeAliases != [ ]) {
        "${nodeIp}" = nodeAliases;
      };

      preNodeHosts = lib.genAttrs linkLocalIps mkPreNodeHost;

      nodeHosts = nodeHost // preNodeHosts;

      yggdrasilHost = lib.optionalAttrs (yggAddress != null) {
        "${yggAddress}" = primaryAliases;
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
