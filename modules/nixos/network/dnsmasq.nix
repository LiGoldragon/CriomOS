{
  config,
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (builtins)
    attrValues
    concatLists
    head
    map
    match
    split
    ;
  inherit (horizon) cluster exNodes node;
  inherit (horizon.node) behavesAs;

  lanBridgeInterface = "br-lan";

  clusterLan =
    cluster.lan
      or (throw "dnsmasq: horizon.cluster.lan is required for router nodes (LAN gateway feeds dnsmasq listen-address)");
  clusterResolver =
    cluster.resolver
      or (throw "dnsmasq: horizon.cluster.resolver is required (local listen addresses come from horizon)");
  resolverDefaults = constants.network.resolver;

  headscaleEnabled = config.services.headscale.enable;
  tailnetBaseDomain = config.services.headscale.settings.dns.base_domain or null;

  # Listen addresses come from horizon.cluster.resolver.listens — typed
  # cluster policy, not a hardcoded ::1/127.0.0.1/lanGateway literal.
  listenAddresses = clusterResolver.listens;

  # Upstream DNS is CriomOS runtime policy. dnsmasq queries primary
  # upstreams first; fallbacks act as backup if primaries fail.
  upstreamServers = resolverDefaults.upstreams ++ resolverDefaults.fallbacks;

  mkAddressRecord =
    {
      name,
      value,
    }:
    "/${name}/${value}";

  sanitizeIp =
    ip:
    if ip == null || ip == "" then
      null
    else
      let
        cleaned = head (split "/" ip);
      in
      if cleaned == "" || match ".*%.*" cleaned != null then null else cleaned;

  horizonNodes = [ node ] ++ attrValues exNodes;

  mkPrimaryAddress =
    entry:
    let
      # Step 14: same regrouping as in network/default.nix —
      # `entry.yggdrasil` is null or `{ pubKey, address, subnet }`.
      yggAddress =
        if entry.yggdrasil == null then null else sanitizeIp entry.yggdrasil.address;
      nodeIp = sanitizeIp entry.nodeIp;
    in
    if yggAddress != null then yggAddress else nodeIp;

  mkPrimaryRecords =
    entry:
    let
      address = mkPrimaryAddress entry;
      # Step 7a: nixCache sub-record replaces nixCacheDomain sibling.
      alias = if entry.nixCache == null then null else entry.nixCache.domain;
      aliasRecords =
        if alias == null || address == null then
          [ ]
        else
          [
            (mkAddressRecord {
              name = alias;
              value = address;
            })
          ];
    in
    if address == null then
      [ ]
    else
      [
        (mkAddressRecord {
          name = entry.criomeDomainName;
          value = address;
        })
      ]
      ++ aliasRecords;

  localAddressRecords = concatLists (map mkPrimaryRecords horizonNodes);

  # `clusterLan` is force-evaluated here so the throw fires loudly on
  # router nodes whose datom forgot to author cluster.lan; it stays
  # lazy on non-router nodes (the whole `mkIf behavesAs.router` block
  # never accesses it).
  _ = clusterLan;
in
lib.mkIf behavesAs.router {
  services = {
    resolved.enable = false;
    unbound.enable = false;
    dnsmasq = {
      enable = true;
      settings = {
        "bind-dynamic" = true;
        "bogus-priv" = true;
        "cache-size" = 1000;
        "domain-needed" = true;
        "listen-address" = listenAddresses;
        "no-resolv" = true;
        interface = [
          "lo"
          lanBridgeInterface
        ];
        address = localAddressRecords;
        server =
          (lib.optionals (headscaleEnabled && tailnetBaseDomain != null) [
            "/${tailnetBaseDomain}/100.100.100.100"
          ])
          ++ upstreamServers;
      };
    };
  };

  systemd.services.dnsmasq.after = [ "systemd-networkd.service" ];
}
