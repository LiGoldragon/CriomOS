"""Run with unshare -Urn for a real link/route delivery witness."""

import ipaddress
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from admission_fixture import AdmissionFixture

source = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(source))
from network import observe, returned, route_changes, snapshot
from delivery import wake

ip = shutil.which("ip")
assert ip
peer = ipaddress.ip_address("192.0.2.2")


def command(*arguments):
    subprocess.run([ip, *arguments], check=True)


def state_machine_contract():
    observed = []
    states = iter([(False, set()), (False, {"other"}), (True, {"test"}),
                   (True, {"test"}), (False, set()), (True, {"test"})])
    observe({}, iter(range(6)), lambda: next(states), observed.append)
    assert len(observed) == 2
    assert returned((True, {"tunnel"}), (True, {"tunnel", "underlay"}))
    assert not returned((False, set()), (False, {"underlay"}))


state_machine_contract()
if len(sys.argv) == 2:
    print("Network event contract: initial and unrelated states are quiet; route and configured link returns wake once.")
    sys.exit(0)

command("link", "set", "lo", "up")
command("link", "add", "source", "type", "veth", "peer", "name", "sink")
command("link", "add", "unrelated", "type", "veth", "peer", "name", "irrelevant")
command("address", "add", "192.0.2.1/24", "dev", "source")
command("link", "set", "sink", "up")

with tempfile.TemporaryDirectory(prefix="network-return-") as temporary:
    root = Path(temporary)
    outbox = root / "outbox"
    outbox.mkdir()
    sender_marker = root / "sender"
    receiver_marker = root / "receiver"
    consumer = AdmissionFixture(root)
    sender_config, receiver_config = root / "sender.json", root / "receiver.json"
    sender = [sys.executable, str(source / "delivery.py"), str(sender_config)]
    receiver = [sys.executable, str(source / "delivery.py"), str(receiver_config)]
    sender_config.write_text(json.dumps(dict(
        repositories=["sample/belief"], outbox=str(outbox), wake=str(sender_marker),
        timeout=5, peerCommand=receiver + ["receive"],
    )))
    receiver_config.write_text(json.dumps(dict(
        repositories=["sample/belief"], wake=str(receiver_marker),
        admissionTimeout=5, curriculumEndpoint=str(consumer.address),
        timeout=5, peerCommand=sender + ["wake"],
    )))
    for index, marker in enumerate((sender_marker, receiver_marker), start=1):
        command("link", "set", "source", "down")
        configuration = dict(ip=ip, wake=str(marker), network=dict(links=["source"]))
        events = route_changes(4)
        next(events)
        before = snapshot(configuration, peer)
        assert not before[0]
        old, new = str(index) * 40, str(index+1) * 40
        subprocess.run(sender + ["enqueue", "sample/belief"],
                       input=f"{old} {new} refs/heads/main\n".encode(), check=True)
        sender_marker.unlink()  # model the drain that woke while the path was down
        command("link", "set", "unrelated", "up" if index == 1 else "down")
        next(events)
        assert not returned(before, snapshot(configuration, peer)) and not marker.exists()
        command("link", "set", "source", "up")
        next(events)
        after = snapshot(configuration, peer)
        assert returned(before, after)
        wake(configuration)
        events.close()
        if marker == receiver_marker:
            subprocess.run(receiver + ["reconnect"], check=True)
            assert not receiver_marker.exists()
        assert sender_marker.exists()
        subprocess.run(sender + ["deliver"], check=True)
        assert not list(outbox.iterdir())
        assert len(consumer.observed) == index
    print("Private network namespace: sender return and receiver return each replayed a pending publication without another push.")
