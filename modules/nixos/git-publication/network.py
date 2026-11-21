"""React to a configured local peer route or link returning."""

import errno
import ipaddress
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys

from delivery import pending_records, wake


# Linux rtnetlink multicast groups for links, addresses and routes.
LINK = 1
IPV4 = 0x10 | 0x40
IPV6 = 0x100 | 0x400
HEADER = struct.Struct("=IHHII")
ROUTE_OR_LINK_CHANGES = {16, 17, 20, 21, 24, 25}


def route_changes(family):
    with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE) as events:
        events.bind((0, LINK | (IPV4 if family == 4 else IPV6)))
        yield  # subscribed before the initial state is read
        while True:
            try:
                batch, _, flags, (process, _) = events.recvmsg(65536)
            except OSError as error:
                if error.errno != errno.ENOBUFS:
                    raise
                yield  # event loss: resnapshot once
                continue
            if process == 0 and (flags & socket.MSG_TRUNC or changed(batch)):
                yield


def changed(batch):
    offset = 0
    while offset + HEADER.size <= len(batch):
        length, kind, _, _, _ = HEADER.unpack_from(batch, offset)
        if length < HEADER.size or offset + length > len(batch):
            break
        if kind in ROUTE_OR_LINK_CHANGES:
            return True
        offset += (length + 3) & ~3
    return False


def ip_json(ip, *arguments):
    observed = subprocess.run(
        [ip, "-json", *arguments], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        check=False,
    )
    return json.loads(observed.stdout) if observed.returncode == 0 else []


def snapshot(configuration, peer):
    links = ip_json(configuration["ip"], "link", "show")
    up = frozenset(
        link["ifname"] for link in links
        if {"UP", "LOWER_UP"}.issubset(link["flags"])
    )
    routes = ip_json(configuration["ip"], f"-{peer.version}", "route", "get", str(peer))
    usable = any(route.get("type", "unicast") in ("unicast", "local")
                 and route.get("dev") in up for route in routes)
    return usable, up.intersection(configuration["network"]["links"])


def returned(previous, current):
    was_usable, previous_links = previous
    usable, links = current
    return usable and (not was_usable or bool(links - previous_links))


def observe(configuration, events, read_state, mark):
    next(events)  # subscribe before reading local state
    previous = read_state()
    if "outbox" in configuration and next(pending_records(Path(configuration["outbox"])), None):
        mark(configuration)
    for _ in events:
        current = read_state()
        if returned(previous, current):
            mark(configuration)
        previous = current


if __name__ == "__main__":
    configuration = json.loads(Path(sys.argv[1]).read_bytes())
    peer = ipaddress.ip_address(configuration["network"]["peerAddress"])
    observe(configuration, route_changes(peer.version), lambda: snapshot(configuration, peer), wake)
