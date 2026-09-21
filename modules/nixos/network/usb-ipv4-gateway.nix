{
  config,
  lib,
  horizon,
  ...
}:
let
  inherit (builtins)
    all
    attrNames
    filter
    fromJSON
    isAttrs
    isList
    isString
    match
    removeAttrs
    ;
  inherit (lib) mkIf mkOption types;
  services = horizon.node.capabilities or [ ];
  records =
    if isList services then services else throw "usbIpv4Gateway: node capabilities must be a list";
  isGateway =
    service:
    isAttrs service && ((service.kind or null) == "usbIpv4Gateway" || service ? usbIpv4Gateway);
  matches = filter isGateway records;
  count = builtins.length matches;
  enabled = count == 1;
  record = if enabled then builtins.head matches else { };
  payload = if record ? usbIpv4Gateway then record.usbIpv4Gateway else removeAttrs record [ "kind" ];
  exactFields = [
    "downstream"
    "downstreamMac"
    "gateway"
    "uplink"
  ];
  hasExactFields = isAttrs payload && attrNames payload == exactFields;
  downstream = payload.downstream or "";
  downstreamMac = payload.downstreamMac or "";
  gateway = payload.gateway or "";
  uplink = payload.uplink or "";
  validIface = value: isString value && match "[a-zA-Z0-9_.-]+" value != null && value != "lo";
  validMac =
    isString downstreamMac
    && match "([0-9a-f]{2}:){5}[0-9a-f]{2}" downstreamMac != null
    && downstreamMac != "00:00:00:00:00:00"
    && builtins.elem (builtins.substring 1 1 downstreamMac) [
      "0"
      "2"
      "4"
      "6"
      "8"
      "a"
      "c"
      "e"
    ];
  cidr =
    if isString gateway then
      match "([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})/([0-9]{1,2})" gateway
    else
      null;
  validCidr =
    cidr != null
    && all (part: fromJSON part <= 255) (lib.take 4 cidr)
    && (
      let
        prefix = fromJSON (builtins.elemAt cidr 4);
      in
      prefix >= 1 && prefix <= 30
    );
  valid =
    hasExactFields
    && validIface downstream
    && validIface uplink
    && downstream != uplink
    && validMac
    && validCidr;
  profileUuid = config.criomos.usbIpv4Gateway.profileUuid;
  validUuid =
    profileUuid != null
    && match "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" profileUuid != null;
  otherSharedProfiles = lib.filterAttrs (
    name: profile: name != "usb-ipv4-gateway" && (profile.ipv4.method or null) == "shared"
  ) config.networking.networkmanager.ensureProfiles.profiles;

  # The firewall module only owns INPUT. These explicit rules also constrain
  # forwarded packets to the declared downstream and uplink pair.
  dhcp = "-i ${downstream} -p udp --dport 67 -m comment --comment criomos-usb-gateway-dhcp -j ACCEPT";
  dnsUdp = "-i ${downstream} -s ${gateway} -p udp --dport 53 -m comment --comment criomos-usb-gateway-dns-udp -j ACCEPT";
  dnsTcp = "-i ${downstream} -s ${gateway} -p tcp --dport 53 -m comment --comment criomos-usb-gateway-dns-tcp -j ACCEPT";
  forwardOut = "-i ${downstream} -o ${uplink} -s ${gateway} -m comment --comment criomos-usb-gateway-forward -j ACCEPT";
  forwardBack = "-i ${uplink} -o ${downstream} -d ${gateway} -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment criomos-usb-gateway-return -j ACCEPT";
  dropDownstream = "-i ${downstream} -m comment --comment criomos-usb-gateway-isolate -j DROP";
  dropToDownstream = "-o ${downstream} -m comment --comment criomos-usb-gateway-inbound -j DROP";
  masquerade = "-s ${gateway} -o ${uplink} -m comment --comment criomos-usb-gateway-nat -j MASQUERADE";
  add =
    table: chain: rule:
    "iptables -w 2 ${table} -C ${chain} ${rule} 2>/dev/null || iptables -w 2 ${table} -I ${chain} 1 ${rule}";
  del =
    table: chain: rule:
    "iptables -w 2 ${table} -C ${chain} ${rule} 2>/dev/null && iptables -w 2 ${table} -D ${chain} ${rule} || true";
in
{
  options.criomos.usbIpv4Gateway.profileUuid = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Existing local NetworkManager profile UUID to reuse during a checkpointed gateway migration.";
  };

  config =
    if count > 1 then
      throw "usbIpv4Gateway: duplicate node services"
    else if enabled && !valid then
      throw "usbIpv4Gateway: invalid service payload"
    else
      mkIf enabled {
        assertions = [
          {
            assertion = config.networking.networkmanager.enable;
            message = "usbIpv4Gateway requires NetworkManager";
          }
          {
            assertion = !config.networking.useNetworkd && !config.systemd.network.enable;
            message = "usbIpv4Gateway cannot share interfaces with systemd-networkd";
          }
          {
            assertion = otherSharedProfiles == { };
            message = "usbIpv4Gateway requires a single declared NetworkManager shared profile";
          }
          {
            assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
            message = "usbIpv4Gateway requires the NixOS iptables firewall as sole NAT/filter owner";
          }
          {
            assertion = !config.networking.nat.enable;
            message = "usbIpv4Gateway cannot coexist with the generic NixOS NAT owner";
          }
        ];

        networking.networkmanager.settings.main."firewall-backend" = "none";
        networking.networkmanager.ensureProfiles.profiles."usb-ipv4-gateway" = {
          connection = {
            id = "usb-ipv4-gateway";
            type = "ethernet";
            uuid =
              if validUuid then
                profileUuid
              else
                throw "usbIpv4Gateway: an existing local NetworkManager profile UUID is required";
            "interface-name" = downstream;
            autoconnect = "true";
            "autoconnect-priority" = "200";
          };
          ethernet."mac-address" = downstreamMac;
          ipv4 = {
            method = "shared";
            address1 = gateway;
            "never-default" = "true";
          };
          ipv6.method = "disabled";
        };
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        networking.firewall.extraCommands = ''
          ${add "" "nixos-fw" dhcp}
          ${add "" "nixos-fw" dnsUdp}
          ${add "" "nixos-fw" dnsTcp}
          ${add "" "FORWARD" dropDownstream}
          ${add "" "FORWARD" dropToDownstream}
          ${add "" "FORWARD" forwardBack}
          ${add "" "FORWARD" forwardOut}
          ${add "-t nat" "POSTROUTING" masquerade}
        '';
        networking.firewall.extraStopCommands = ''
          ${del "" "nixos-fw" dhcp}
          ${del "" "nixos-fw" dnsUdp}
          ${del "" "nixos-fw" dnsTcp}
          ${del "" "FORWARD" forwardOut}
          ${del "" "FORWARD" forwardBack}
          ${del "" "FORWARD" dropDownstream}
          ${del "" "FORWARD" dropToDownstream}
          ${del "-t nat" "POSTROUTING" masquerade}
        '';
      };
}
