# The daisy chain as a NixOS VM test: Internet reaches a leaf through two
# UsbDownlink hops, each on a real (emulated) USB Ethernet NIC.
#
#   upstream  --vlan 1--  ouranos           (NetworkManager node, UsbDownlink)
#                         ouranos USB NIC --vlan 2--  prometheus eth1 (WAN)
#                                                     prometheus (Router + UsbDownlink)
#                                                     prometheus USB NIC --vlan 3-- client eth1
#
# The integrated NICs are virtio PCI; each downlink is a QEMU usb-net device
# on an xHCI controller, so the guest sees ID_BUS=usb exactly as it does on
# hardware. `upstream` stands in for the ISP and the Internet: it hands out
# DHCP on vlan 1, answers DNS as 1.1.1.1 (the address Prometheus's dnsmasq
# forwards to) and serves HTTP, and it has no route to either downlink
# network, so every packet that reaches it must have been masqueraded.
{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  constants = inputs.criomos-lib.lib.constants;

  downlink = network: {
    kind = "usbDownlink";
    ipv4Network = network;
  };

  # A USB Ethernet NIC on its own xHCI controller, wired to a test vlan.
  usbNic =
    { vlan, mac }:
    [
      "-device qemu-xhci,id=downlink-xhci"
      ''-netdev vde,id=usbdownlink,sock="$QEMU_VDE_SOCKET_${toString vlan}"''
      "-device usb-net,id=usbdownlink-nic,bus=downlink-xhci.0,netdev=usbdownlink,mac=${mac}"
    ];
  # The router module shapes its config on horizon, so horizon must reach
  # it as an argument rather than through _module.args (which depends on
  # config). The test framework has one specialArgs for every node; this
  # applies the module to the node's own horizon instead.
  withHorizon =
    horizon: path:
    let
      module = import path;
    in
    {
      _file = toString path;
      imports = [
        (lib.setFunctionArgs (args: module (args // { inherit horizon; })) (
          removeAttrs (builtins.functionArgs module) [ "horizon" ]
        ))
      ];
    };

  prometheusHorizon = {
    cluster = "goldragon";
    exNodes = { };
    domainConfiguration.publicClusterDomains = [ ];
    node = {
      name = "prometheus";
      criomeDomainName = "prometheus.goldragon.criome";
      nixCacheDomain = null;
      keys.yggdrasil = null;
      capabilities = [ (downlink constants.network.lan.subnet) ];
      behavesAs.router = true;
      network.routerInterfaces = {
        wan = "eth1";
        wlan = "wlan0";
        wlanBand = "2g";
        wlanChannel = 6;
        wlanStandard = "wifi4";
        ssid = "usb-downlink-chain";
        country = "PL";
        wpa3SaePasswordReference = "fixtureWifiPassword";
      };
    };
  };

  ouranosUsbMac = "52:54:00:44:00:02";
  prometheusUsbMac = "52:54:00:18:00:03";

  # Every node's only NICs are the ones the test declares: no user-mode
  # network, no automatic test addresses.
  integratedNic = vlan: {
    virtualisation.qemu.networkingOptions = lib.mkForce [ ];
    virtualisation.interfaces.eth1 = {
      inherit vlan;
      assignIP = false;
    };
    networking.useDHCP = false;
  };
in
pkgs.testers.runNixOSTest {
  name = "usb-downlink-chain";

  node.specialArgs = {
    inherit constants;
    inputs = inputs // {
      secrets.sopsFiles.fixtureWifiPassword = builtins.toFile "fixture-wifi-password" "";
    };
  };

  nodes = {
    upstream =
      { ... }:
      {
        imports = [ (integratedNic 1) ];
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "192.168.1.1";
            prefixLength = 24;
          }
        ];
        networking.interfaces.lo.ipv4.addresses = [
          {
            address = "1.1.1.1";
            prefixLength = 32;
          }
        ];
        networking.firewall.enable = false;
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            bind-interfaces = true;
            listen-address = [
              "192.168.1.1"
              "1.1.1.1"
            ];
            no-resolv = true;
            address = "/example.test/1.1.1.1";
            dhcp-range = "192.168.1.50,192.168.1.99,1h";
            dhcp-option = [
              "option:router,192.168.1.1"
              "option:dns-server,1.1.1.1"
            ];
          };
        };
        services.nginx = {
          enable = true;
          virtualHosts.internet = {
            default = true;
            locations."/".return = "200 'daisy-chain-ok'";
          };
        };
      };

    ouranos =
      { ... }:
      {
        imports = [
          (integratedNic 1)
          ../../modules/nixos/network/usb-downlink.nix
          ../../modules/nixos/network/resolver.nix
        ];
        _module.args.horizon.node = {
          capabilities = [ (downlink "10.44.0.0/24") ];
          enableNetworkManager = true;
          behavesAs = {
            router = false;
            center = false;
          };
        };
        networking.networkmanager.enable = true;
        virtualisation.qemu.options = usbNic {
          vlan = 2;
          mac = ouranosUsbMac;
        };
        environment.systemPackages = [ pkgs.iproute2 ];
      };

    prometheus =
      { lib, ... }:
      {
        imports = [
          (integratedNic 2)
          inputs.sops-nix.nixosModules.sops
          (withHorizon prometheusHorizon ../../modules/nixos/router/default.nix)
          ../../modules/nixos/network/dnsmasq.nix
          ../../modules/nixos/network/usb-downlink.nix
        ];
        _module.args.horizon = prometheusHorizon;
        # The VM has no radio and no sops key: the access point is the
        # router's other feature and is not what this test is about.
        services.hostapd.enable = lib.mkForce false;
        sops.secrets = lib.mkForce { };
        virtualisation.qemu.options = usbNic {
          vlan = 3;
          mac = prometheusUsbMac;
        };
        environment.systemPackages = [
          pkgs.dig
          pkgs.curl
        ];
      };

    client =
      { ... }:
      {
        imports = [ (integratedNic 3) ];
        networking.useNetworkd = true;
        systemd.network.networks."10-eth1" = {
          matchConfig.Name = "eth1";
          networkConfig.DHCP = "ipv4";
        };
        services.resolved.enable = true;
        environment.systemPackages = [
          pkgs.dig
          pkgs.curl
        ];
      };
  };

  testScript = ''
    import re

    def usb_nics(machine):
        """The node's USB Ethernet NICs, found by udev bus role."""
        out = machine.succeed(
            "for link in /sys/class/net/*; do "
            "udevadm info -q property -p \"$link\" | grep -qx 'ID_BUS=usb' && basename \"$link\"; "
            "done; true"
        )
        return out.split()

    def only_usb_nic(machine):
        nics = usb_nics(machine)
        assert len(nics) == 1, f"{machine.name}: expected one USB NIC, found {nics}"
        return nics[0]

    def bridge_of(machine, link):
        return machine.succeed(f"basename \"$(readlink /sys/class/net/{link}/master)\" 2>/dev/null || true").strip()

    def wait_bridged(machine, bridge):
        machine.wait_until_succeeds(
            f"for link in /sys/class/net/*; do "
            f"udevadm info -q property -p \"$link\" | grep -qx 'ID_BUS=usb' "
            f"&& [ \"$(basename \"$(readlink \"$link/master\")\")\" = {bridge} ] && exit 0; "
            f"done; exit 1",
            timeout=120,
        )

    start_all()

    with subtest("upstream: the stand-in Internet is up"):
        upstream.wait_for_unit("dnsmasq.service")
        upstream.wait_for_unit("nginx.service")

    with subtest("hop A: ouranos takes its uplink on the integrated NIC"):
        ouranos.wait_for_unit("NetworkManager.service")
        ouranos.wait_until_succeeds("ip -4 route show default | grep -q 'via 192.168.1.1 dev eth1'", timeout=120)
        ouranos_uplink = ouranos.succeed("ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        assert re.fullmatch(r"192\.168\.1\.\d+", ouranos_uplink), ouranos_uplink
        ouranos.succeed("udevadm info -q property -p /sys/class/net/eth1 | grep -qx 'ID_BUS=pci'")

    with subtest("hop B: ouranos serves its USB downlink by bus role"):
        wait_bridged(ouranos, "br-downlink")
        ouranos_usb = only_usb_nic(ouranos)
        assert ouranos_usb != "eth1"
        assert bridge_of(ouranos, "eth1") == "", "the integrated NIC must never be a downlink"
        ouranos.succeed("ip -4 -o addr show dev br-downlink | grep -q ' 10.44.0.1/24 '")
        ouranos.succeed(f"nmcli -t -f DEVICE,STATE device | grep -qx '{ouranos_usb}:unmanaged'")
        ouranos.succeed("nmcli -t -f DEVICE,STATE device | grep -qx 'eth1:connected'")
        ouranos.wait_for_unit("kea-dhcp4-server.service")
        ouranos.succeed("iptables -w -t nat -S nixos-nat-post | grep -q MASQUERADE")

    with subtest("hop B: prometheus takes a lease from ouranos on its integrated NIC"):
        prometheus.wait_until_succeeds("ip -4 route show default | grep -q 'via 10.44.0.1 dev eth1'", timeout=180)
        prometheus.succeed("ip -4 -o addr show dev eth1 | grep -q ' 10.44.0.'")
        prometheus.succeed("ping -c1 -W2 10.44.0.1")
        dns = prometheus.succeed("dig +short +time=3 +tries=2 @10.44.0.1 example.test").strip()
        assert dns == "1.1.1.1", f"DNS at the ouranos gateway returned {dns!r}"
        prometheus.succeed("curl -4 -sf --max-time 10 --interface eth1 http://1.1.1.1/ | grep -qx daisy-chain-ok")

    with subtest("hop C: prometheus's router bridges its USB NIC into br-lan"):
        wait_bridged(prometheus, "br-lan")
        prometheus_usb = only_usb_nic(prometheus)
        assert bridge_of(prometheus, "eth1") == "", "the router WAN must never join the LAN bridge"
        prometheus.wait_for_unit("kea-dhcp4-server.service")
        prometheus.wait_for_unit("dnsmasq.service")
        prometheus.fail("iptables -w -t nat -S 2>/dev/null | grep -q MASQUERADE")
        assert prometheus.succeed("nft list ruleset | grep -c masquerade").strip() == "1", "exactly one NAT owner on prometheus"

    with subtest("hop D: the client fetches through the chain over its wired NIC"):
        client.wait_until_succeeds("ip -4 route show default | grep -q 'via 10.18.0.1 dev eth1'", timeout=180)
        client.succeed("ping -c1 -W2 10.18.0.1")
        dns = client.succeed("dig +short +time=3 +tries=2 @10.18.0.1 example.test").strip()
        assert dns == "1.1.1.1", f"DNS at the prometheus gateway returned {dns!r}"
        client.wait_until_succeeds("curl -4 -sf --max-time 10 --interface eth1 http://example.test/ | grep -qx daisy-chain-ok", timeout=60)
        seen = upstream.succeed("tail -n1 /var/log/nginx/access.log | cut -d' ' -f1").strip()
        assert seen == ouranos_uplink, f"upstream saw {seen}, not ouranos's uplink {ouranos_uplink}"
        upstream.fail("ip -4 route get 10.18.0.1 | grep -q ' via '")

    with subtest("hotplug: re-plugging each USB NIC converges to the same roles"):
        prometheus.send_monitor_command("device_del usbdownlink-nic")
        prometheus.wait_until_succeeds(f"! test -e /sys/class/net/{prometheus_usb}", timeout=60)
        prometheus.send_monitor_command(
            "device_add usb-net,id=usbdownlink-nic,bus=downlink-xhci.0,netdev=usbdownlink,mac=${prometheusUsbMac}"
        )
        wait_bridged(prometheus, "br-lan")
        ouranos.send_monitor_command("device_del usbdownlink-nic")
        ouranos.wait_until_succeeds(f"! test -e /sys/class/net/{ouranos_usb}", timeout=60)
        ouranos.send_monitor_command(
            "device_add usb-net,id=usbdownlink-nic,bus=downlink-xhci.0,netdev=usbdownlink,mac=${ouranosUsbMac}"
        )
        wait_bridged(ouranos, "br-downlink")
        ouranos.succeed(f"nmcli -t -f DEVICE,STATE device | grep -qx '{only_usb_nic(ouranos)}:unmanaged'")
        prometheus.succeed("networkctl renew eth1")
        client.succeed("networkctl renew eth1")
        client.wait_until_succeeds("curl -4 -sf --max-time 10 --interface eth1 http://example.test/ | grep -qx daisy-chain-ok", timeout=120)

    with subtest("no upstream, no Internet: the leaf fails rather than passing"):
        upstream.succeed("ip link set eth1 down")
        client.fail("curl -4 -sf --max-time 8 --interface eth1 http://1.1.1.1/")
  '';
}
