{ pkgs, ... }:

pkgs.testers.runNixOSTest {
  name = "preferred-wired-internet";
  nodes = {
    client =
      { lib, pkgs, ... }:
      {
        imports = [ ../../modules/nixos/network/preferred-wired-internet.nix ];
        _module.args.horizon.node.capabilities = [
          {
            kind = "preferredWiredInternet";
            interface = "eth1";
          }
        ];
        virtualisation.vlans = [ 1 2 ];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
          interfaces.eth2.ipv4.addresses = lib.mkForce [ ];
          firewall.enable = false;
          networkmanager = {
            enable = true;
            dns = "systemd-resolved";
            ensureProfiles.profiles.fixture-other-link = {
              connection = {
                id = "fixture-other-link";
                uuid = "63e42372-c121-41b0-9130-f8329eaf2ec9";
                type = "ethernet";
                interface-name = "eth2";
                autoconnect = true;
                autoconnect-priority = 20;
              };
              ethernet = { };
              ipv4 = {
                method = "auto";
                route-metric = 600;
                dns-priority = 100;
                dns-search = "~mgmt.test;";
              };
              ipv6.method = "auto";
            };
          };
        };
        services.resolved.enable = true;
        environment.systemPackages = [ pkgs.tcpdump ];
      };

    router =
      { lib, pkgs, ... }:
      {
        virtualisation.vlans = [ 1 2 ];
        networking = {
          useDHCP = false;
          firewall.enable = false;
          interfaces.eth1.ipv4.addresses = lib.mkForce [
            { address = "10.91.1.1"; prefixLength = 24; }
          ];
          interfaces.eth2.ipv4.addresses = lib.mkForce [
            { address = "10.91.2.1"; prefixLength = 24; }
          ];
        };
        services.dnsmasq = {
          enable = true;
          settings = {
            interface = [ "eth1" "eth2" ];
            bind-interfaces = true;
            no-resolv = true;
            dhcp-authoritative = true;
            dhcp-range = [
              "set:wire,10.91.1.20,10.91.1.29,255.255.255.0,1h"
              "set:other,10.91.2.20,10.91.2.29,255.255.255.0,1h"
            ];
            dhcp-option = [
              "tag:wire,option:router,10.91.1.1"
              "tag:wire,option:dns-server,10.91.1.1"
              "tag:other,option:router,10.91.2.1"
              "tag:other,option:dns-server,10.91.2.1"
            ];
            address = [ "/example.test/192.0.2.21" "/mgmt.test/192.0.2.22" ];
          };
        };
        environment.systemPackages = [ pkgs.tcpdump ];
      };
  };

  testScript = ''
    start_all()
    router.wait_for_unit("dnsmasq.service")
    client.wait_for_unit("NetworkManager.service")
    client.wait_until_succeeds("nmcli -t -f NAME connection show | grep -Fx criomos-preferred-wired")
    client.wait_for_unit("systemd-resolved.service")

    client.succeed("nmcli --wait 20 connection up id fixture-other-link ifname eth2")
    client.succeed("nmcli --wait 20 connection up id criomos-preferred-wired ifname eth1")
    client.succeed("ip -4 route show default | grep -E 'via 10[.]91[.]1[.]1 dev eth1 .*metric 100'")
    client.succeed("ip -4 route show default | grep -E 'via 10[.]91[.]2[.]1 dev eth2 .*metric 600'")

    def inspect_lookup(name, expected_interface, answer):
        # Capture both isolated virtual links for one bounded transaction.
        for interface in ("eth1", "eth2"):
            path = f"/tmp/{name}.{interface}"
            router.succeed(f'timeout 5 tcpdump -n -l -i {interface} "udp dst port 53" >{path} 2>&1 &')
            router.wait_until_succeeds(f"grep -q 'listening on' {path}")
        reply = client.succeed(f"resolvectl query --cache=no --type=A {name}")
        assert answer in reply, reply
        assert f"link: {expected_interface}" in reply, reply
        router.wait_until_succeeds(f"grep -Fq '{name}' /tmp/{name}.{expected_interface}")
        other = "eth2" if expected_interface == "eth1" else "eth1"
        # Wait for the wrong-link capture to drain after the response.
        router.succeed(f"sleep 1; ! grep -Fq '{name}' /tmp/{name}.{other}")

    inspect_lookup("ordinary.example.test", "eth1", "192.0.2.21")
    inspect_lookup("host.mgmt.test", "eth2", "192.0.2.22")

    client.succeed("nmcli --wait 10 device disconnect eth1")
    client.succeed("ip -4 route show default | grep -E 'via 10[.]91[.]2[.]1 dev eth2 .*metric 600'")
    inspect_lookup("fallback.example.test", "eth2", "192.0.2.21")
  '';
}
