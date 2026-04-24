{
  config,
  constants,
  lib,
  pkgs,
  horizon,
  ...
}:
let
  inherit (builtins)
    map
    concatLists
    concatStringsSep
    attrNames
    attrValues
    split
    head
    match
    ;
  inherit (lib) filter mapAttrsToList concatMapStringsSep lowPrio;
  inherit (horizon) cluster node exNodes;
  inherit (horizon.node) behavesAs;

  tailnetBaseDomain = "tailnet.${cluster.name}.criome";
  headscaleEnabled = config.services.headscale.enable;

  lanGateway = constants.network.lan.gateway;
  lanSubnet = constants.network.lan.subnet;

  # Router nodes also listen on br-lan so wifi/LAN clients can resolve DNS.
  listenIPs = [
    "::1"
    "127.0.0.1"
  ] ++ lib.optionals behavesAs.router [
    lanGateway
  ];

  TLSDNServers = {
    "cloudflare-dns.com" = [
      "2606:4700:4700::1111"
      "1.1.1.1"
      "2606:4700:4700::1001"
      "1.0.0.1"
    ];
    "dns.quad9.net" = [
      "2620:fe::fe"
      "9.9.9.9"
      "2620:fe::9"
      "149.112.112.112"
    ];
  };

  mkForwardServerUrls = domain: ipList: map (ip: "${ip}@853#${domain}") ipList;

  forwardServerUrls = concatLists (map (name: mkForwardServerUrls name TLSDNServers.${name}) (attrNames TLSDNServers));

  mkRecord = { name, rtype, value }:
    "\"${concatStringsSep " " [
      name
      "IN"
      rtype
      value
    ]}\"";

  sanitizeIp = ip:
    if ip == null || ip == "" then
      null
    else
      let
        cleaned = head (split "/" ip);
      in
        if cleaned == "" || match ".*%.*" cleaned != null then null else cleaned;

  recordTypeForIp = ip:
    if match ".*:.*" ip != null then "AAAA" else "A";

  horizonNodes = [ node ] ++ attrValues exNodes;

  mkPrimaryAddress = entry:
    let
      yggAddress = sanitizeIp entry.yggAddress;
      nodeIp = sanitizeIp entry.nodeIp;
    in
      if yggAddress != null then yggAddress else nodeIp;

  mkPrimaryRecords = entry:
    let
      address = mkPrimaryAddress entry;
      alias = entry.nixCacheDomain;
      aliasRecords =
        if alias == null || alias == "" || address == null then
          []
        else
          [ (mkRecord { name = alias; rtype = recordTypeForIp address; value = address; }) ];
    in
      if address == null then
        []
      else
        [ (mkRecord { name = entry.criomeDomainName; rtype = recordTypeForIp address; value = address; }) ] ++ aliasRecords;

  localDnsRecords = concatLists (map mkPrimaryRecords horizonNodes);

in
{
  systemd.services.unbound.after = lib.optionals behavesAs.router [ "systemd-networkd.service" ];

  services.unbound = {
    # enable = (!typeIs.edge); # bootstrap
    enable = true;
    settings = {
      server = {
        interface = listenIPs;
        access-control = [
          "127.0.0.0/8 allow"
          "::1/128 allow"
        ] ++ lib.optionals behavesAs.router [
          "${lanSubnet} allow"
        ];
        do-not-query-localhost = false;
        tls-cert-bundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        local-data = localDnsRecords;
      };
      forward-zone =
        (lib.optionals headscaleEnabled [
          {
            # Split-DNS for our headscale tailnet base domain.
            # This lets us keep `tailscale up --accept-dns=false` later.
            name = "${tailnetBaseDomain}.";
            forward-addr = [ "100.100.100.100" ];
          }
        ])
        ++ [
          {
            name = ".";
            forward-tls-upstream = true;
            forward-addr = forwardServerUrls;
          }
        ];
    };
  };

}
