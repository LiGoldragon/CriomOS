"""Durable publication delivery on an authenticated SSH command boundary."""

import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def store(directory, name, data):
    """Publish a complete record once. Return after the directory is durable."""
    destination = directory / name
    with tempfile.NamedTemporaryFile(dir=directory) as pending:
        pending.write(data)
        pending.flush()
        os.fsync(pending.fileno())
        try:
            os.link(pending.name, destination)
        except FileExistsError:
            if destination.read_bytes() != data:
                raise ValueError("existing record differs")
        sync_directory(directory)


def event(configuration, repository, reference, old, new):
    if repository not in configuration["repositories"] or reference != "refs/heads/main":
        raise ValueError("repository or ref is not configured")
    if re.fullmatch(r"[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+", repository) is None:
        raise ValueError("invalid repository name")
    if not (
        len(old) == len(new)
        and len(old) in (40, 64)
        and re.fullmatch(r"[0-9a-f]+", old)
        and re.fullmatch(r"[0-9a-f]+", new)
    ):
        raise ValueError("invalid Git object IDs")
    data = f"{{ {repository} {reference} {old} {new} }}\n".encode("ascii")
    if len(data) > 256:
        raise ValueError("publication exceeds its wire budget")
    return data


def checked_event(configuration, data):
    begin, repository, reference, old, new, end = data.decode("ascii").split()
    if begin != "{" or end != "}" or event(configuration, repository, reference, old, new) != data:
        raise ValueError("publication must use canonical Datom")
    return hashlib.sha256(data).hexdigest()


def wake(configuration):
    signal = Path(configuration["wake"])
    try:
        descriptor = os.open(signal, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        pass
    else:
        os.close(descriptor)
    sync_directory(signal.parent)


def enqueue(configuration, repository):
    if repository not in configuration["repositories"]:
        return
    outbox = Path(configuration["outbox"])
    for update in sys.stdin:
        old, new, reference = update.split()
        if reference != "refs/heads/main":
            continue
        data = event(configuration, repository, reference, old, new)
        store(outbox, checked_event(configuration, data) + ".datom", data)
        wake(configuration)


def receive(configuration):
    data = sys.stdin.buffer.read(257)
    if len(data) > 256:
        raise ValueError("publication exceeds its wire budget")
    identity = checked_event(configuration, data)
    store(Path(configuration["inbox"]), identity + ".datom", data)
    announce(configuration, identity, data)
    print(f"Stored.{identity}", flush=True)


def announce(configuration, identity, data):
    _, repository, reference, old, new, _ = data.decode("ascii").split()
    announcement = (
        f"PublicationStored.{{ {identity} {{ {{ {repository} {reference} }} {old} {new} }} }}\n"
    ).encode("ascii")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as consumer:
        consumer.settimeout(configuration["admissionTimeout"])
        consumer.connect(configuration["curriculumEndpoint"])
        consumer.sendall(announcement)
        consumer.shutdown(socket.SHUT_WR)
        with consumer.makefile("rb") as reply:
            if reply.read(128) != f"Accepted.{identity}\n".encode("ascii"):
                raise ValueError("Curriculum gave no matching durable admission")


def call(configuration, data):
    return subprocess.run(
        [os.path.expandvars(argument) for argument in configuration["peerCommand"]],
        input=data, stdout=subprocess.PIPE,
        check=True, timeout=configuration["timeout"],
    ).stdout


def deliver(configuration):
    signal = Path(configuration["wake"])
    signal.unlink(missing_ok=True)
    outbox = Path(configuration["outbox"])
    for record in sorted(outbox.glob("*.datom")):
        data = record.read_bytes()
        identity = checked_event(configuration, data)
        if record.name != identity + ".datom":
            raise ValueError("outbox name does not match publication")
        if call(configuration, data) != f"Stored.{identity}\n".encode("ascii"):
            raise ValueError("receiver gave no matching durable acknowledgement")
        record.unlink()
        sync_directory(outbox)


def reconnect(configuration):
    if call(configuration, b"") != b"Ready\n":
        raise ValueError("sender did not acknowledge reconnect")


def main():
    configuration = json.loads(Path(sys.argv[1]).read_bytes())
    match sys.argv[2:]:
        case ["enqueue", repository]:
            enqueue(configuration, repository)
        case ["receive"]:
            receive(configuration)
        case ["deliver"]:
            deliver(configuration)
        case ["reconnect"]:
            reconnect(configuration)
        case ["wake"]:
            if sys.stdin.buffer.read(1):
                raise ValueError("wake takes an empty request")
            wake(configuration)
            print("Ready", flush=True)
        case _:
            raise ValueError("invalid publication operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
