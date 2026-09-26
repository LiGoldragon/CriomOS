# USB downlink: the node propagates its Internet access to whatever is
# plugged into its USB Ethernet NICs. The integrated NIC is the uplink and
# every USB Ethernet NIC is a downlink, selected by udev bus role, never by
# name or MAC, so it works however the cables are plugged.
#
# Horizon declares it as the capability
#   { kind = "usbDownlink"; ipv4Network = "10.44.0.0/24"; }
# The network's first host address is the gateway served on the downlinks.
#
# On a node without the Router feature this module owns the whole hop:
#   - systemd-networkd enslaves every USB Ethernet link to one bridge and
#     puts the gateway address on it (so any number of dongles share one
#     subnet and one DHCP server);
#   - Kea serves DHCP on the bridge (the router feature's DHCP server);
#   - systemd-resolved answers DNS on the gateway address;
#   - the NixOS NAT module masquerades what arrives on the bridge to
#     whichever link carries the default route (the integrated uplink);
#   - the NixOS firewall admits DHCP and DNS on the bridge only.
#   On a NetworkManager node, NetworkManager is told by udev to leave USB
#   Ethernet links alone, so each link has exactly one manager.
#
# On a node with the Router feature the router module already bridges
# USB Ethernet into its LAN with the same bus-role match, serves Kea and DNS
# there, and is the node's only NAT owner (its nftables table). This module
# then adds nothing but the check that the declared downlink network is the
# router LAN; a second bridge, DHCP server or masquerade would make two
# owners of one hop.
{
  config,
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  inherit (builtins)
    elemAt
    filter
    fromJSON
    isAttrs
    isList
    length
    match
    ;
  inherit (lib)
    concatStringsSep
    mkDefault
    mkIf
    mkMerge
    ;

  usbEthernet = import ./usb-ethernet-role.nix { inherit lib; };

  capabilities = horizon.node.capabilities or [ ];
  isUsbDownlink = capability: isAttrs capability && (capability.kind or null) == "usbDownlink";
  declarations =
    if isList capabilities then
      filter isUsbDownlink capabilities
    else
      throw "usbDownlink: horizon.node.capabilities must be a list";
  declared = declarations != [ ];
  declaration =
    if length declarations == 1 then
      builtins.head declarations
    else
      throw "usbDownlink: a node declares at most one UsbDownlink capability";
  isRouter = horizon.node.behavesAs.router or false;

  # IPv4 arithmetic on the declared network, so the gateway, pool and
  # netmask all derive from the one declared value.
  parsedNetwork =
    let
      parts = match "([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})/([0-9]{1,2})" (
        declaration.ipv4Network or ""
      );
      octets = map (index: fromJSON (elemAt parts index)) [
        0
        1
        2
        3
      ];
      prefix = fromJSON (elemAt parts 4);
      address = lib.foldl (sum: octet: sum * 256 + octet) 0 octets;
      size = lib.foldl (product: _: product * 2) 1 (lib.range 1 (32 - prefix));
    in
    if parts == null then
      throw "usbDownlink: ipv4Network ${toString (declaration.ipv4Network or null)} is not an IPv4 CIDR"
    else if lib.any (octet: octet > 255) octets then
      throw "usbDownlink: ipv4Network ${declaration.ipv4Network} has an octet above 255"
    else if prefix < 16 || prefix > 28 then
      throw "usbDownlink: ipv4Network ${declaration.ipv4Network} must have a prefix from /16 to /28"
    else if lib.mod address size != 0 then
      throw "usbDownlink: ipv4Network ${declaration.ipv4Network} has host bits set; declare the network address"
    else
      {
        inherit address prefix size;
        cidr = declaration.ipv4Network;
      };
  render =
    value:
    concatStringsSep "." (
      map (shift: toString (lib.mod (value / shift) 256)) [
        16777216
        65536
        256
        1
      ]
    );
  network = parsedNetwork;
  gateway = render (network.address + 1);
  gatewayWithPrefix = "${gateway}/${toString network.prefix}";
  poolFirst = render (network.address + 10);
  poolLast = render (network.address + network.size - 2);

  bridge = "br-downlink";

  routerLan = constants.network.lan.subnet;

  # Field's pre-declaration hotfix on ouranos, removed by the same
  # generation that declares the downlink. It lives inside this capability:
  # a node without the UsbDownlink declaration may still depend on it.
  hotfixRemoval = import ./usb-downlink-hotfix.nix {
    inherit pkgs;
    systemd = config.systemd.package;
    networkmanager =
      if config.networking.networkmanager.enable then config.networking.networkmanager.package else null;
  };
in
{
  config = mkIf declared (mkMerge [
    {
      # Evaluate the declaration eagerly so a malformed network fails the
      # build rather than a later reference.
      assertions = [
        {
          assertion = network.cidr == declaration.ipv4Network;
          message = "usbDownlink: the declared network did not parse";
        }
      ];

      # Activation, not tmpfiles: switch-to-configuration runs activation
      # before its daemon-reload and unit restarts, so firewall.service is
      # reloaded in this same switch without the hotfix drop-in.
      system.activationScripts.usbDownlinkLegacyHotfix = {
        text = "${hotfixRemoval}/bin/usb-downlink-remove-hotfix /";
        deps = [ ];
      };
    }

    (mkIf isRouter {
      assertions = [
        {
          assertion = network.cidr == routerLan;
          message = "usbDownlink: on a Router node the downlink network (${network.cidr}) must be the router LAN (${routerLan}); the router module owns the USB downlink there";
        }
      ];
    })

    (mkIf (!isRouter) {
      assertions = [
        {
          assertion = config.services.resolved.enable;
          message = "usbDownlink: the downlink's DNS is served by systemd-resolved, which this node does not enable";
        }
      ];

      systemd.network = {
        enable = true;
        # networkd owns only the downlink here; NetworkManager (or the
        # node's own networkd rules) decide when the node is online.
        wait-online.enable = mkIf (!config.networking.useNetworkd) (mkDefault false);

        netdevs."20-${bridge}".netdevConfig = {
          Kind = "bridge";
          Name = bridge;
        };

        networks = {
          # Sorts before every Ethernet catch-all: networkd applies the
          # first matching file.
          "05-usb-downlink" = {
            matchConfig = usbEthernet.networkdMatch { };
            networkConfig = {
              Bridge = bridge;
              ConfigureWithoutCarrier = true;
            };
            linkConfig.RequiredForOnline = "no";
          };

          "40-${bridge}" = {
            matchConfig.Name = bridge;
            address = [ gatewayWithPrefix ];
            networkConfig = {
              ConfigureWithoutCarrier = true;
              # Link-local IPv6 only, for directly attached Yggdrasil peer
              # discovery; the downlink is an IPv4 service.
              LinkLocalAddressing = "ipv6";
              IPv6AcceptRA = false;
            };
            linkConfig.RequiredForOnline = "no";
          };
        };
      };

      # NetworkManager must not also claim the USB links or the bridge.
      services.udev.extraRules = mkIf config.networking.networkmanager.enable ''
        ${usbEthernet.udevMatch}, ENV{NM_UNMANAGED}="1"
      '';
      networking.networkmanager.unmanaged = [ "interface-name:${bridge}" ];

      services.kea.dhcp4 = {
        enable = true;
        settings = {
          valid-lifetime = 4000;
          renew-timer = 1000;
          rebind-timer = 2000;
          interfaces-config = {
            interfaces = [ bridge ];
            dhcp-socket-type = "raw";
            service-sockets-max-retries = 60;
            service-sockets-retry-wait-time = 1000;
          };
          lease-database = {
            type = "memfile";
            persist = true;
            name = "/var/lib/kea/dhcp4.leases";
          };
          subnet4 = [
            {
              id = 1;
              subnet = network.cidr;
              pools = [ { pool = "${poolFirst} - ${poolLast}"; } ];
              option-data = [
                {
                  name = "routers";
                  data = gateway;
                }
                {
                  name = "domain-name-servers";
                  data = gateway;
                }
              ];
            }
          ];
        };
      };
      systemd.services.kea-dhcp4-server.after = [ "systemd-networkd.service" ];

      services.resolved.settings.Resolve.DNSStubListenerExtra = gateway;

      networking.nat = {
        enable = true;
        # No external interface: masquerade toward whichever link carries
        # the route, which is the integrated uplink's default route.
        internalInterfaces = [ bridge ];
      };

      networking.firewall.interfaces.${bridge} = {
        allowedUDPPorts = [
          53
          67
        ];
        allowedTCPPorts = [ 53 ];
      };
    })
  ]);
}
