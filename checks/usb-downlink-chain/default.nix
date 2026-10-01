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
{
  inputs,
  pkgs,
  moduleRoot ? ../..,
  legacyWanFixture ? false,
  ...
}:
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
      network.routerInterfaces = lib.optionalAttrs legacyWanFixture { wan = "eth1"; } // {
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
  globalTimeout = 900;

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
        # dnsmasq binds 192.168.1.1 and 1.1.1.1 by address (bind-interfaces),
        # so it must start only once the scripted networking has put both
        # addresses on their links.
        systemd.services.dnsmasq = {
          after = [
            "network-addresses-lo.service"
            "network-addresses-eth1.service"
          ];
          requires = [
            "network-addresses-lo.service"
            "network-addresses-eth1.service"
          ];
        };
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
          (moduleRoot + "/modules/nixos/network/usb-downlink.nix")
          (moduleRoot + "/modules/nixos/network/resolver.nix")
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
        # Two integrated upstream candidates exercise the explicit policy.
        virtualisation.interfaces.eth2 = {
          vlan = 1;
          assignIP = false;
        };
        virtualisation.qemu.options = usbNic {
          vlan = 2;
          mac = ouranosUsbMac;
        };
        environment.systemPackages = [
          pkgs.iproute2
          pkgs.curl
          pkgs.procps
          pkgs.iw
          pkgs.hostapd
          pkgs.dnsmasq
          pkgs.python3
        ];
        boot.kernelModules = [ "mac80211_hwsim" ];
      };

    prometheus =
      { lib, ... }:
      {
        imports = [
          (integratedNic 2)
          inputs.sops-nix.nixosModules.sops
          (withHorizon prometheusHorizon (moduleRoot + "/modules/nixos/router/default.nix"))
          (moduleRoot + "/modules/nixos/network/dnsmasq.nix")
          (moduleRoot + "/modules/nixos/network/usb-downlink.nix")
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
          pkgs.procps
          pkgs.python3
        ];
      };

    client =
      { ... }:
      {
        imports = [
          (integratedNic 3)
          (moduleRoot + "/modules/nixos/network/usb-downlink.nix")
        ];
        _module.args.horizon.node = {
          capabilities = [ (downlink "10.45.0.0/24") ];
          behavesAs.router = false;
        };
        networking.useNetworkd = true;
        services.resolved.enable = true;
        environment.systemPackages = [
          pkgs.dig
          pkgs.curl
          pkgs.procps
          pkgs.python3
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
        ouranos.wait_until_succeeds("ip -4 route show default | grep -Eq 'via 192.168.1.1 dev eth[12]'", timeout=120)
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
        ouranos.succeed("nmcli -t -f DEVICE,STATE device | grep -qx 'eth1:unmanaged'")
        ouranos.wait_for_unit("kea-dhcp4-server.service")
        assert ouranos.succeed("nft list table ip nixos-nat | grep -c masquerade").strip() == "1"
        assert ouranos.succeed("systemctl show kea-dhcp4-server -p MainPID --value").strip() != "0"
        ouranos.succeed("nft list table ip nixos-nat | grep -q masquerade")
        ouranos.wait_for_unit("dnsmasq.service")
        ouranos.fail("systemctl is-active systemd-resolved.service")
        ouranos.fail("systemctl is-active usb-downlink-observer.service")
        ouranos.succeed("nmcli -t -f DEVICE,STATE device | grep -qx 'eth2:unmanaged'")
        ouranos.wait_until_succeeds("networkctl status eth2 | grep -q configured", timeout=120)
        assert bridge_of(ouranos, "eth2") == ""


    with subtest("hop B: prometheus takes a lease from ouranos on its integrated NIC"):
        prometheus.wait_until_succeeds("ip -4 route show default | grep -q 'via 10.44.0.1 dev eth1'", timeout=180)
        prometheus.succeed("ip -4 -o addr show dev eth1 | grep -q ' 10.44.0.'")
        prometheus.succeed("ping -c1 -W2 10.44.0.1")
        dns = prometheus.succeed("dig +short +time=3 +tries=2 @10.44.0.1 example.test").strip()
        assert dns == "1.1.1.1", f"DNS at the ouranos gateway returned {dns!r}"
        prometheus.succeed("curl -4 -sf --max-time 10 --interface eth1 http://1.1.1.1/ | grep -qx daisy-chain-ok")

    with subtest("host resolver and late upstream DNS"):
        for machine in [ouranos, prometheus]:
            machine.succeed("grep -q 'nameserver 127.0.0.1' /etc/resolv.conf")
            machine.wait_until_succeeds("getent ahostsv4 example.test | grep -q 1.1.1.1", timeout=60)
            machine.fail("systemctl is-active systemd-resolved.service")
            machine.succeed("test $(pgrep -xc dnsmasq) = 1")
        upstream.succeed("systemctl stop dnsmasq")
        ouranos.succeed("networkctl renew eth1 eth2")
        upstream.succeed("systemctl start dnsmasq")
        ouranos.wait_until_succeeds("getent ahostsv4 example.test | grep -q 1.1.1.1", timeout=120)

    with subtest("hop C: prometheus's router bridges its USB NIC into br-lan"):
        wait_bridged(prometheus, "br-lan")
        prometheus_usb = only_usb_nic(prometheus)
        assert bridge_of(prometheus, "eth1") == "", "the router WAN must never join the LAN bridge"
        prometheus.wait_for_unit("kea-dhcp4-server.service")
        prometheus.wait_for_unit("dnsmasq.service")
        prometheus.succeed("nft list table ip nixos-nat | grep -q masquerade")
        for machine, bridge in [(ouranos, "br-downlink"), (prometheus, "br-lan"), (client, "br-downlink")]:
            machine.wait_for_unit("kea-dhcp4-server.service")
            bridges = machine.succeed("ip -o link show type bridge | awk -F': ' '{print $2}'").split()
            assert bridges == [bridge], bridges
            assert machine.succeed("pgrep -xc kea-dhcp4").strip() == "1"
            assert machine.succeed("nft list table ip nixos-nat | grep -c masquerade").strip() == "1"
        assert prometheus.succeed("nft list ruleset | grep -c masquerade").strip() == "1", "exactly one NAT owner on prometheus"

    with subtest("hop D: the client fetches through the chain over its wired NIC"):
        client.wait_until_succeeds("ip -4 route show default | grep -q 'via 10.18.0.1 dev eth1'", timeout=180)
        client.succeed("ping -c1 -W2 10.18.0.1")
        dns = client.succeed("dig +short +time=3 +tries=2 @10.18.0.1 example.test").strip()
        assert dns == "1.1.1.1", f"DNS at the prometheus gateway returned {dns!r}"
        client.wait_until_succeeds("curl -4 -sf --max-time 10 --interface eth1 http://example.test/ | grep -qx daisy-chain-ok", timeout=60)
        selected_source = ouranos.succeed("ip -4 route get 1.1.1.1 | sed -n 's/.* src \([^ ]*\).*/\1/p'").strip()
        seen = upstream.succeed("tail -n1 /var/log/nginx/access.log | cut -d' ' -f1").strip()
        assert seen == selected_source, f"upstream saw {seen}, not selected route source {selected_source}"
        upstream.fail("ip -4 route get 10.18.0.1 | grep -q ' via '")

    with subtest("inbound services remain closed from upstream"):
        prometheus.succeed("systemd-run --unit=inbound-fixture python3 -m http.server 8443 --bind 0.0.0.0")
        client.wait_until_succeeds("curl -4 -sf --max-time 3 http://10.18.0.1:8443/ >/dev/null", timeout=30)
        wan_address = prometheus.succeed("ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        ouranos.fail(f"curl -4 -sf --max-time 3 http://{wan_address}:8443/ >/dev/null")

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

    with subtest("integrated upstream selection survives interface renaming"):
        ouranos.succeed("ip link set eth2 down; ip link set eth2 name built_in_backup; ip link set built_in_backup up")
        ouranos.succeed("udevadm trigger --action=add /sys/class/net/built_in_backup")
        ouranos.wait_until_succeeds("networkctl status built_in_backup | grep -q configured", timeout=120)
        ouranos.succeed("nmcli -t -f DEVICE,STATE device | grep -qx 'built_in_backup:unmanaged'")
        assert bridge_of(ouranos, "built_in_backup") == ""

    with subtest("real Wi-Fi recovery carries downstream traffic with wired uplinks absent"):
        # A simulated radio AP in its own network namespace is a separate
        # upstream, not a route through the host's loopback or wired ports.
        ouranos.wait_until_succeeds("test -e /sys/class/net/wlan0 && test -e /sys/class/net/wlan1")
        ouranos.succeed("ip netns add wifi-upstream; iw phy phy0 set netns name wifi-upstream")
        ouranos.succeed("ip netns exec wifi-upstream ip link set lo up; ip netns exec wifi-upstream ip addr add 1.1.1.1/32 dev lo")
        ouranos.succeed("ip netns exec wifi-upstream ip addr add 192.168.77.1/24 dev wlan0")
        ouranos.succeed("printf 'interface=wlan0\\ndriver=nl80211\\nssid=recovery-fixture\\nhw_mode=g\\nchannel=6\\n' > /tmp/recovery-hostapd.conf")
        ouranos.succeed("ip netns exec wifi-upstream hostapd -B /tmp/recovery-hostapd.conf")
        ouranos.succeed("mkdir /tmp/recovery-web; printf daisy-chain-ok > /tmp/recovery-web/index.html")
        ouranos.succeed("systemd-run --unit=recovery-web ip netns exec wifi-upstream python3 -m http.server 80 --directory /tmp/recovery-web")
        ouranos.succeed("ip netns exec wifi-upstream dnsmasq --no-resolv --bind-interfaces --listen-address=1.1.1.1 --address=/recovery.test/1.1.1.1 --pid-file=/tmp/recovery-dns.pid")
        ouranos.succeed("nmcli connection add type wifi ifname wlan1 con-name recovery ssid recovery-fixture ipv4.method manual ipv4.addresses 192.168.77.2/24 ipv4.gateway 192.168.77.1 ipv4.ignore-auto-dns yes ipv6.method disabled")
        ouranos.wait_until_succeeds("nmcli connection up recovery", timeout=120)
        ouranos.succeed("ip link set eth1 down; ip link set built_in_backup down")
        ouranos.wait_until_succeeds("ip -4 route get 1.1.1.1 | grep -q 'dev wlan1'", timeout=120)
        ouranos.succeed("systemctl restart dnsmasq")
        ouranos.wait_until_succeeds("getent ahostsv4 recovery.test | grep -q 1.1.1.1", timeout=60)
        client.wait_until_succeeds("curl -4 -sf --max-time 10 http://1.1.1.1/ | grep -qx daisy-chain-ok", timeout=120)
        # The AP has no downstream route; NAT is required for the reply.
        ouranos.fail("ip netns exec wifi-upstream ip -4 route get 10.18.0.1 | grep -q ' via '")
        ouranos.succeed("systemd-run --unit=recovery-inbound python3 -m http.server 8443 --bind 0.0.0.0")
        ouranos.wait_until_succeeds("curl -4 -sf --max-time 3 http://127.0.0.1:8443/ >/dev/null", timeout=30)
        ouranos.fail("ip netns exec wifi-upstream curl -4 -sf --max-time 3 http://192.168.77.2:8443/")
        ouranos.succeed("nmcli connection down recovery")

    with subtest("no upstream, no Internet: the leaf fails rather than passing"):
        upstream.succeed("ip link set eth1 down")
        client.fail("curl -4 -sf --max-time 8 --interface eth1 http://1.1.1.1/")
  '';
}
