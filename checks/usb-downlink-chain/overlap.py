# Proposed policy only: no runtime guard is installed by this fixture.
# Keep every negative observation; the final assertion is the expected red.
with subtest("PROPOSED overlap contract: Ethernet and Wi-Fi prefix changes"):
    import shlex
    dhcp_probe = r"""
import json, os, socket, struct, time
mac = bytes.fromhex("525400990001")
xid = os.getpid()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"probe0\0")
s.bind(("0.0.0.0", 68))
# Receive at Ethernet level before the addressless client's IP route checks.
rx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
rx.bind(("probe0", 0))
base = struct.pack("!BBBBIHHIIII16s64s128s", 1, 1, 6, 0, xid, 0, 0x8000,
    0, 0, 0, 0, mac + bytes(10), bytes(64), bytes(128))
def send(options):
    s.sendto(base + bytes.fromhex("63825363") + options + bytes([255]), ("255.255.255.255", 67))
def receive(kind):
    deadline = time.monotonic() + 10
    while True:
        assert time.monotonic() < deadline, "bounded DHCP exchange expired"
        rx.settimeout(max(0.001, deadline - time.monotonic()))
        frame = rx.recv(4096)
        if len(frame) < 42 or frame[12:14] != bytes.fromhex("0800") or frame[23] != 17:
            continue
        ihl = (frame[14] & 15) * 4
        udp = 14 + ihl
        if struct.unpack("!HH", frame[udp:udp+4]) != (67, 68):
            continue
        data = frame[udp+8:]
        if len(data) < 240 or data[0] != 2 or data[4:8] != struct.pack("!I", xid):
            continue
        assert data[28:34] == mac and data[236:240] == bytes.fromhex("63825363")
        options, i = {}, 240
        while i < len(data):
            code = data[i]; i += 1
            if code == 255: break
            if code == 0: continue
            length = data[i]; i += 1
            assert i + length <= len(data)
            options[code] = data[i:i+length]; i += length
        if options.get(53) == bytes([kind]):
            return data[16:20], options
        assert time.monotonic() < deadline, "bounded DHCP exchange expired"
send(bytes([53, 1, 1, 55, 3, 1, 3, 6]))
address, offer = receive(2)
assert 54 in offer, "offer lacks server identity"
send(bytes([53, 1, 3, 50, 4]) + address + bytes([54, 4]) + offer[54]
    + bytes([55, 3, 1, 3, 6]))
ack_address, ack = receive(5)
assert ack_address == address and ack[54] == offer[54]
assert ack[1] == socket.inet_aton("255.255.255.0")
assert ack[3] == socket.inet_aton("10.44.0.1")
assert ack[6] == socket.inet_aton("10.44.0.1")
assert address[:3] == bytes([10, 44, 0]) and 10 <= address[3] <= 254
print(json.dumps({"result": "DHCP_ACK", "address": socket.inet_ntoa(address)}))
"""
    violations = []
    def fetch(machine, address):
        status, body = machine.execute(f"curl -4 -sf --max-time 5 http://{address}/")
        return status == 0 and body.strip() == "daisy-chain-ok"

    def local_services(label):
        prometheus.succeed("ping -c1 -W2 10.44.0.1")
        prometheus.succeed("dig +short +time=2 +tries=1 @10.44.0.1 example.test | grep -qx 1.1.1.1")
        ouranos.succeed("systemctl is-active kea-dhcp4-server.service dnsmasq.service")
        lease = json.loads(ouranos.succeed("ip netns exec overlap-dhcp python3 -c " + shlex.quote(dhcp_probe)))
        assert lease["result"] == "DHCP_ACK", f"{label}: fresh DHCP exchange failed"
        assert fetch(client, "1.1.1.2"), f"{label}: disjoint uplink stopped forwarding"

    ouranos.succeed("ip netns add overlap-dhcp; ip link add overlap-port type veth peer name probe0; ip link set overlap-port master br-downlink; ip link set overlap-port up; ip link set probe0 netns overlap-dhcp; ip netns exec overlap-dhcp ip link set probe0 address 52:54:00:99:00:01; ip netns exec overlap-dhcp ip link set probe0 up")
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
    ouranos.succeed("ip link del overlap-port; ip netns del overlap-dhcp")
    assert not violations, f"PROPOSED selective overlap block absent: {violations}"
