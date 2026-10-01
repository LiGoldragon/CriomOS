# One declared USB-sharing capability owns wired roles, downstream bridge,
# address, DHCP, DNS integration and the NixOS nftables firewall/NAT policy.
# NetworkManager retains Wi-Fi recovery: Field witnessed it live on Zeus
# while wired carrier was absent. All Ethernet and the bridge are excluded
# from NM. Replacing its radio/authentication behavior is a separate task.
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
  poolFirst = render (network.address + (if isRouter then 100 else 10));
  poolLast = render (network.address + (if isRouter then 240 else network.size - 2));

  bridge = if isRouter then "br-lan" else "br-downlink";

  routerLan = constants.network.lan.subnet;

in
{
  imports = [ ./dnsmasq.nix ];
  options.criomos.usbDownlink = {
    bridge = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = bridge;
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = if declared then gateway else "";
    };
  };
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

    }

    (mkIf isRouter {
      assertions = [
        {
          assertion = network.cidr == routerLan;
          message = "usbDownlink: on a Router node the downlink network (${network.cidr}) must be the router LAN (${routerLan}); the shared capability owns the router USB downlink";
        }
      ];
    })

    {

      systemd.network = {
        enable = true;
        # networkd owns Ethernet; Wi-Fi recovery remains independently managed.
        # Downlink readiness must not block workstation startup.
        wait-online.enable = mkIf (!config.networking.useNetworkd) (mkDefault false);

        netdevs."20-${bridge}".netdevConfig = {
          Kind = "bridge";
          Name = bridge;
        };

        networks = {
          # Every integrated Ethernet NIC is an upstream candidate; USB,
          # radio and virtual links never enter this match.
          "10-upstream" = {
            matchConfig = {
              Type = "ether";
              Property = "ID_BUS=pci";
            };
            networkConfig = {
              DHCP = "ipv4";
              IPv6AcceptRA = true;
              KeepConfiguration = "dynamic-on-stop";
            };
            dhcpV4Config = {
              SendRelease = false;
              UseDNS = false;
              RouteMetric = 100;
              MaxAttempts = "infinity";
            };
            linkConfig.RequiredForOnline = "no";
          };
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
        SUBSYSTEM=="net", ENV{ID_BUS}=="pci", ATTR{type}=="1", ENV{DEVTYPE}!="wlan", ENV{DEVTYPE}!="wwan", ENV{NM_UNMANAGED}="1"
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

      # DNS is one system dnsmasq on loopback and the downstream bridge.
      services.resolved.enable = lib.mkForce false;
      networking.resolvconf.enable = lib.mkForce false;
      # With both dynamic resolver writers disabled, own the host file directly.
      environment.etc."resolv.conf".text = ''
        nameserver 127.0.0.1
        nameserver ::1
      '';
      networking.nameservers = lib.mkForce [
        "127.0.0.1"
        "::1"
      ];
      networking.networkmanager.dns = lib.mkForce "none";

      networking.nftables.enable = true;
      networking.firewall = {
        enable = true;
        filterForward = true;
      };
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
    }
  ]);
}
