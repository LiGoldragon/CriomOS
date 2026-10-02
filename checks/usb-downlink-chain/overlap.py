# Proposed policy only: no runtime guard is installed by this fixture.
# Keep every negative observation; the final assertion is the expected red.
with subtest("PROPOSED overlap contract: Ethernet and Wi-Fi prefix changes"):
    violations = []
    def fetch(machine, address):
        status, body = machine.execute(f"curl -4 -sf --max-time 5 http://{address}/")
        return status == 0 and body.strip() == "daisy-chain-ok"

    def local_services(label):
        prometheus.succeed("ping -c1 -W2 10.44.0.1")
        prometheus.succeed("dig +short +time=2 +tries=1 @10.44.0.1 example.test | grep -qx 1.1.1.1")
        ouranos.succeed("test $(pgrep -xc kea-dhcp4) = 1; test $(pgrep -xc dnsmasq) = 1")
        assert fetch(client, "1.1.1.2"), f"{label}: disjoint uplink stopped forwarding"

    upstream.succeed("ip addr add 1.1.1.2/32 dev lo")
    ouranos.succeed("ip link set uplink_a up; ip link set built_in_backup up")
    ouranos.wait_until_succeeds("ip -4 addr show uplink_a | grep -q 'inet 192.168.1.'", timeout=120)
    ouranos.wait_until_succeeds("ip -4 addr show built_in_backup | grep -q 'inet 192.168.4.'", timeout=120)
    ouranos.succeed("ip route replace 1.1.1.2/32 via 192.168.4.1 dev built_in_backup")
    ouranos.succeed("ip route replace 1.1.1.1/32 via 192.168.1.1 dev uplink_a")
    client.wait_until_succeeds("curl -4 -sf --max-time 5 http://1.1.1.1/ | grep -qx daisy-chain-ok", timeout=60)
    client.wait_until_succeeds("curl -4 -sf --max-time 5 http://1.1.1.2/ | grep -qx daisy-chain-ok", timeout=60)

    # Address events cover equal and containing prefixes. The healthy original
    # lease stays, so a blocked fetch cannot be credited to a dead upstream.
    for address in ["10.44.0.200/24", "10.44.200.200/16"]:
        label = f"Ethernet {address}"
        ouranos.succeed(f"ip addr add {address} dev uplink_a")
        assert fetch(ouranos, "1.1.1.1"), f"{label}: host recovery path must remain usable"
        local_services(label)
        if fetch(client, "1.1.1.1"):
            violations.append(label)
        ouranos.succeed(f"ip addr del {address} dev uplink_a")
        client.wait_until_succeeds("curl -4 -sf --max-time 5 http://1.1.1.1/ | grep -qx daisy-chain-ok", timeout=60)

    ouranos.succeed("nmcli connection up recovery")
    ouranos.succeed("ip route replace 1.1.1.1/32 via 192.168.77.1 dev wlan1")
    client.wait_until_succeeds("curl -4 -sf --max-time 5 http://1.1.1.1/ | grep -qx daisy-chain-ok", timeout=60)
    for address in ["10.44.0.201/24", "10.44.201.201/16"]:
        label = f"Wi-Fi {address}"
        ouranos.succeed(f"nmcli connection modify recovery +ipv4.addresses {address}; nmcli device reapply wlan1")
        ouranos.wait_until_succeeds(f"ip -4 addr show wlan1 | grep -Fq '{address}'", timeout=60)
        assert fetch(ouranos, "1.1.1.1"), f"{label}: host recovery path must remain usable"
        local_services(label)
        if fetch(client, "1.1.1.1"):
            violations.append(label)
        ouranos.succeed(f"nmcli connection modify recovery -ipv4.addresses {address}; nmcli device reapply wlan1")
        client.wait_until_succeeds("curl -4 -sf --max-time 5 http://1.1.1.1/ | grep -qx daisy-chain-ok", timeout=60)

    # Restore the preceding test's no-uplink state even on an expected red.
    ouranos.succeed("nmcli connection down recovery; ip route del 1.1.1.1/32; ip route del 1.1.1.2/32; ip link set uplink_a down; ip link set built_in_backup down")
    assert not violations, f"PROPOSED selective overlap block absent: {violations}"
