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
    concatMap
    head
    map
    match
    split
    ;
  inherit (horizon) exNodes node;
  inherit (horizon.node) behavesAs;

  lanBridgeInterface = "br-lan";
  lanGateway = constants.network.lan.gateway;

  headscaleEnabled = config.services.headscale.enable;
  tailnetBaseDomain = config.services.headscale.settings.dns.base_domain or null;

  # Router nodes listen on loopback for local system lookups and on
  # br-lan's gateway address for WiFi/LAN clients.
  listenAddresses = [
    "::1"
    "127.0.0.1"
    lanGateway
  ];

  publicClusterDomains = horizon.domainConfiguration.publicClusterDomains or [ ];

  # The router takes its upstream DNS from its current uplinks, as each
  # uplink's DHCP gives it: networkd hands each link's servers to resolved,
  # which sends a query to every link holding a default route and keeps the
  # first answer, so a dead uplink's resolver is passed over.  dnsmasq
  # serves the LAN and forwards to resolved's stub.
  resolvedStub = "127.0.0.53";

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
      yggAddress = sanitizeIp (
        if entry.keys.yggdrasil == null then null else entry.keys.yggdrasil.address
      );
      nodeIp = sanitizeIp (entry.network.nodeIp or null);
    in
    if yggAddress != null then yggAddress else nodeIp;

  mkPrimaryRecords =
    entry:
    let
      address = mkPrimaryAddress entry;
      alias = entry.nixCacheDomain;
      internalAliasRecords =
        if alias == null || alias == "" || address == null then
          [ ]
        else
          [
            (mkAddressRecord {
              name = alias;
              value = address;
            })
          ];
      publicNodeRecords = concatMap (domain: [
        (mkAddressRecord {
          name = "${entry.name}.${domain}";
          value = address;
        })
      ]) publicClusterDomains;
      publicNixCacheRecords =
        if alias == null || alias == "" then
          [ ]
        else
          concatMap (domain: [
            (mkAddressRecord {
              name = "nix.${entry.name}.${domain}";
              value = address;
            })
          ]) publicClusterDomains;
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
      ++ internalAliasRecords
      ++ publicNodeRecords
      ++ publicNixCacheRecords;

  localAddressRecords = concatLists (map mkPrimaryRecords horizonNodes);
in
lib.mkIf behavesAs.router {
  services = {
    resolved = {
      enable = true;
      settings.Resolve = {
        DNS = lib.mkForce [ ];
        FallbackDNS = lib.mkForce [ ];
        DNSStubListener = "yes";
        LLMNR = "no";
        MulticastDNS = "no";
      };
    };
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
          ++ [ resolvedStub ];
      };
    };
  };

  # Local lookups go through dnsmasq too, for the cluster's address records.
  environment.etc."resolv.conf" = lib.mkForce {
    text = ''
      nameserver 127.0.0.1
      nameserver ::1
      options edns0
    '';
  };

  systemd.services.dnsmasq.after = [
    "systemd-networkd.service"
    "systemd-resolved.service"
  ];
}
