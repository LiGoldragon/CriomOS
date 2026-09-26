# Evaluation policy for the UsbDownlink feature (network/usb-downlink.nix):
# what it declares on a NetworkManager node, on a networkd center node, and
# on a Router node, and what it refuses.
{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  constants = inputs.criomos-lib.lib.constants;
  downlink = network: {
    kind = "usbDownlink";
    ipv4Network = network;
  };

  edge =
    capabilities:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants;
        horizon.node = {
          inherit capabilities;
          enableNetworkManager = true;
          behavesAs = {
            router = false;
            center = false;
          };
        };
      };
      modules = [
        ../../modules/nixos/network/usb-downlink.nix
        ../../modules/nixos/network/resolver.nix
        ../../modules/nixos/network/networkd.nix
        { networking.networkmanager.enable = true; }
      ];
    };

  center =
    capabilities:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants;
        horizon.node = {
          inherit capabilities;
          behavesAs = {
            router = false;
            center = true;
          };
        };
      };
      modules = [
        ../../modules/nixos/network/usb-downlink.nix
        ../../modules/nixos/network/networkd.nix
      ];
    };

  router =
    capabilities:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants;
        horizon = {
          cluster = "goldragon";
          node = {
            name = "usb-downlink-router-fixture";
            inherit capabilities;
            behavesAs.router = true;
            network.routerInterfaces = {
              wan = "eno1";
              wlan = "wlan0";
              wlanBand = "2g";
              wlanChannel = 6;
              wlanStandard = "wifi4";
              ssid = "usb-downlink-router-fixture";
              country = "PL";
              wpa3SaePasswordReference = "fixtureWifiPassword";
            };
          };
        };
        inputs = inputs // {
          secrets.sopsFiles.fixtureWifiPassword = builtins.toFile "fixture-wifi-password" "";
        };
      };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/router/default.nix
        ../../modules/nixos/network/usb-downlink.nix
        { nixpkgs.config.allowUnfree = true; }
      ];
    };

  # Only this feature's assertions: the fixtures are not bootable systems.
  failedAssertions =
    configuration:
    lib.filter (lib.hasPrefix "usbDownlink") (
      map (item: item.message) (lib.filter (item: !item.assertion) configuration.assertions)
    );
  rejects =
    capabilities:
    !(builtins.tryEval (builtins.deepSeq (failedAssertions (edge capabilities).config) true)).success;

  gatewayNode = (edge [ (downlink "10.44.0.0/24") ]).config;
  plainNode = (edge [ ]).config;
  centerNode = (center [ (downlink "10.47.0.0/24") ]).config;
  plainCenter = (center [ ]).config;
  routerNode = (router [ (downlink constants.network.lan.subnet) ]).config;
  foreignRouter = (router [ (downlink "10.44.0.0/24") ]).config;

  networks = gatewayNode.systemd.network.networks;
  usbRule = networks."05-usb-downlink";
  bridgeRule = networks."40-br-downlink";
  kea = gatewayNode.services.kea.dhcp4.settings;
  subnet = builtins.head kea.subnet4;
  option = name: (lib.findFirst (item: item.name == name) null subnet.option-data).data;
  matches =
    link: link.Type == usbRule.matchConfig.Type && link.Property == usbRule.matchConfig.Property;
  routerUsb = routerNode.systemd.network.networks."05-usb-eth";
in
assert lib.assertMsg (failedAssertions gatewayNode == [ ]) (
  "gateway fixture has failed assertions: " + toString (failedAssertions gatewayNode)
);
# Selection is by bus role only.
assert lib.assertMsg (
  usbRule.matchConfig == {
    Type = "ether";
    Property = "ID_BUS=usb";
  }
) "the downlink rule must select USB Ethernet by bus role, with no name or MAC";
assert lib.assertMsg (matches {
  Type = "ether";
  Property = "ID_BUS=usb";
}) "a USB Ethernet NIC is a downlink";
assert lib.assertMsg (
  !matches {
    Type = "ether";
    Property = "ID_BUS=pci";
  }
) "the integrated PCI NIC is never a downlink";
assert lib.assertMsg (
  "05-usb-downlink" < "10-main-eth"
) "the downlink rule sorts before Ethernet catch-alls";
assert lib.assertMsg (
  usbRule.networkConfig.Bridge == "br-downlink"
) "every USB downlink joins one bridge";
# Addressing, DHCP, DNS.
assert lib.assertMsg (
  bridgeRule.address == [ "10.44.0.1/24" ]
) "the bridge carries the network's first host address";
assert lib.assertMsg (
  kea.interfaces-config.interfaces == [ "br-downlink" ]
) "Kea serves only the downlink bridge";
assert lib.assertMsg (subnet.subnet == "10.44.0.0/24") "Kea serves the declared network";
assert lib.assertMsg (
  subnet.pools == [ { pool = "10.44.0.10 - 10.44.0.254"; } ]
) "the pool stays inside the declared network";
assert lib.assertMsg (
  option "routers" == "10.44.0.1" && option "domain-name-servers" == "10.44.0.1"
) "clients route and resolve through the gateway";
assert lib.assertMsg (
  gatewayNode.services.resolved.settings.Resolve.DNSStubListenerExtra == "10.44.0.1"
) "resolved answers DNS on the gateway";
# NAT, firewall, ownership.
assert lib.assertMsg (
  gatewayNode.networking.nat.enable
  && gatewayNode.networking.nat.internalInterfaces == [ "br-downlink" ]
  && gatewayNode.networking.nat.externalInterface == null
) "the node masquerades the bridge toward its default route";
assert lib.assertMsg (
  gatewayNode.networking.firewall.interfaces.br-downlink.allowedUDPPorts == [
    53
    67
  ]
) "the firewall admits DHCP and DNS on the bridge";
assert lib.assertMsg (
  lib.hasInfix ''ENV{ID_BUS}=="usb"'' gatewayNode.services.udev.extraRules
  && lib.hasInfix ''ENV{NM_UNMANAGED}="1"'' gatewayNode.services.udev.extraRules
) "NetworkManager leaves USB Ethernet to networkd";
assert lib.assertMsg
  (builtins.elem "interface-name:br-downlink" gatewayNode.networking.networkmanager.unmanaged)
  "NetworkManager leaves the bridge alone";
assert lib.assertMsg (
  gatewayNode.networking.networkmanager.ensureProfiles.profiles == { }
) "no NetworkManager shared profile is declared";
assert lib.assertMsg (
  !gatewayNode.systemd.network.wait-online.enable
) "networkd's wait-online does not gate a NetworkManager node";
assert lib.assertMsg (
  let
    text = gatewayNode.system.activationScripts.usbDownlinkLegacyHotfix;
  in
  lib.hasInfix "prometheus-share-temporary" text && lib.hasInfix "90-field-prometheus-usb.conf" text
) "activation names the undeclared hotfix while it exists";
# Absent capability: nothing.
assert lib.assertMsg (
  !plainNode.services.kea.dhcp4.enable
  && !plainNode.networking.nat.enable
  && !(plainNode.systemd.network.netdevs ? "20-br-downlink")
  && !(plainNode.system.activationScripts ? usbDownlinkLegacyHotfix)
) "a node without the capability gets no downlink";
# Center node: the declared downlink replaces the undeclared hotplug rule.
assert lib.assertMsg (
  !(centerNode.systemd.network.networks ? "05-usb-eth")
  && centerNode.systemd.network.networks."40-br-downlink".address == [ "10.47.0.1/24" ]
) "on a networkd center node the declared downlink replaces the hotplug rule";
assert lib.assertMsg (
  plainCenter.systemd.network.networks ? "05-usb-eth"
) "a center node without the capability keeps its hotplug rule";
# Router node: the router module is the one owner.
assert lib.assertMsg (failedAssertions routerNode == [ ]) (
  "router fixture has failed assertions: " + toString (failedAssertions routerNode)
);
assert lib.assertMsg (
  !routerNode.networking.nat.enable
  && !(routerNode.systemd.network.netdevs ? "20-br-downlink")
  && !(routerNode.systemd.network.networks ? "05-usb-downlink")
  && routerNode.services.kea.dhcp4.settings.interfaces-config.interfaces == [ "br-lan" ]
  && lib.hasInfix ''oifname "eno1" masquerade'' routerNode.networking.nftables.ruleset
) "on a Router node the router module stays the single bridge, DHCP and NAT owner";
assert lib.assertMsg (
  routerUsb.matchConfig == {
    Type = "ether";
    Property = "ID_BUS=usb";
    Name = "!eno1";
  }
) "the router's USB LAN rule is the shared bus-role match minus its WAN";
assert lib.assertMsg (builtins.any (lib.hasInfix "must be the router LAN") (
  failedAssertions foreignRouter
)) "a Router node refuses a downlink network other than its LAN";
# Malformed declarations fail.
assert lib.assertMsg (rejects [ (downlink "10.44.0.1/24") ]) "a network with host bits is refused";
assert lib.assertMsg (rejects [ (downlink "10.44.0.0/33") ]) "an impossible prefix is refused";
assert lib.assertMsg (rejects [
  (downlink "10.44.0.0/30")
]) "a network too small for a pool is refused";
assert lib.assertMsg (rejects [ (downlink "10.444.0.0/24") ]) "an octet above 255 is refused";
assert lib.assertMsg (rejects [
  (downlink "10.44.0.0/24")
  (downlink "10.45.0.0/24")
]) "two declarations are refused";
pkgs.runCommand "usb-downlink-policy" { } ''
  touch "$out"
''
