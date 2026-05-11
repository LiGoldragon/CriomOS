{
  config,
  constants,
  lib,
  horizon,
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
  lanGateway = constants.network.lan.gateway;

  tailnetBaseDomain = "tailnet.${cluster.name}.criome";
  headscaleEnabled = config.services.headscale.enable;

  # Router nodes listen on loopback for local system lookups and on
  # br-lan's gateway address for WiFi/LAN clients.
  listenAddresses = [
    "::1"
    "127.0.0.1"
    lanGateway
  ];

  upstreamServers = [
    "1.1.1.1"
    "1.0.0.1"
    "2606:4700:4700::1111"
    "2606:4700:4700::1001"
    "9.9.9.9"
    "149.112.112.112"
    "2620:fe::fe"
    "2620:fe::9"
  ];

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
      yggAddress = sanitizeIp entry.yggAddress;
      nodeIp = sanitizeIp entry.nodeIp;
    in
    if yggAddress != null then yggAddress else nodeIp;

  mkPrimaryRecords =
    entry:
    let
      address = mkPrimaryAddress entry;
      alias = entry.nixCacheDomain;
      aliasRecords =
        if alias == null || alias == "" || address == null then
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
          (lib.optionals headscaleEnabled [
            "/${tailnetBaseDomain}/100.100.100.100"
          ])
          ++ upstreamServers;
      };
    };
  };

  systemd.services.dnsmasq.after = [ "systemd-networkd.service" ];
}
