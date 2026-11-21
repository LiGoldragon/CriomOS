"""Durable publication delivery on an authenticated SSH command boundary."""

from dataclasses import dataclass
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


WIRE_BUDGET = 256


@dataclass(frozen=True)
class PublicationStream:
    repository_name: str
    reference_name: str


@dataclass(frozen=True)
class ObjectId:
    text: str

    def __post_init__(self):
        if len(self.text) not in (40, 64) or re.fullmatch(r"[0-9a-f]+", self.text) is None:
            raise ValueError("invalid Git object ID")


@dataclass(frozen=True)
class Publication:
    stream: PublicationStream
    old: ObjectId
    new: ObjectId

    def wire(self):
        if len(self.old.text) != len(self.new.text):
            raise ValueError("Git object IDs have different widths")
        stream = self.stream
        data = (
            f"{{ {stream.repository_name} {stream.reference_name} "
            f"{self.old.text} {self.new.text} }}\n"
        ).encode("ascii")
        if len(data) > WIRE_BUDGET:
            raise ValueError("publication exceeds its wire budget")
        return data

    def announcement(self):
        stream = self.stream
        return (
            f"PublicationReceived.{{ {{ {stream.repository_name} {stream.reference_name} }} "
            f"{self.old.text} {self.new.text} }}\n"
        ).encode("ascii")

    def digest(self):
        return hashlib.sha256(self.wire()).hexdigest()


def configured_streams(configuration):
    return {
        PublicationStream(stream["repositoryName"], stream["referenceName"])
        for stream in configuration["streams"]
    }


def read_publication(data, streams):
    begin, repository, reference, old, new, end = data.decode("ascii").split()
    stream = PublicationStream(repository, reference)
    if begin != "{" or end != "}" or stream not in streams:
        raise ValueError("publication is not on a configured stream")
    publication = Publication(stream, ObjectId(old), ObjectId(new))
    if publication.wire() != data:
        raise ValueError("publication must use canonical Datom")
    return publication


REFUSALS = (b"Refused.Untrusted\n", b"Refused.Invalid\n", b"Refused.Unavailable\n")


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
    streams = configured_streams(configuration)
    outbox = Path(configuration["outbox"])
    for update in sys.stdin:
        old, new, reference = update.split()
        stream = PublicationStream(repository, reference)
        if stream not in streams:
            continue
        publication = Publication(stream, ObjectId(old), ObjectId(new))
        store(outbox, publication.digest() + ".datom", publication.wire())
        wake(configuration)


def receive(configuration):
    try:
        data = sys.stdin.buffer.read(WIRE_BUDGET + 1)
        if len(data) > WIRE_BUDGET:
            raise ValueError("publication exceeds its wire budget")
        publication = read_publication(data, configured_streams(configuration))
    except ValueError:
        reply = b"Refused.Invalid\n"
    else:
        reply = announce(configuration, publication)
    sys.stdout.buffer.write(reply)
    sys.stdout.buffer.flush()


def announce(configuration, publication):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as consumer:
            consumer.settimeout(configuration["admissionTimeout"])
            consumer.connect(configuration["curriculumEndpoint"])
            consumer.sendall(publication.announcement())
            consumer.shutdown(socket.SHUT_WR)
            with consumer.makefile("rb") as reply_stream:
                reply = reply_stream.readline(128)
    except OSError:
        return b"Refused.Unavailable\n"
    if reply in REFUSALS or re.fullmatch(rb"Accepted\.[0-9a-f]{64}\n", reply):
        return reply
    return b"Refused.Unavailable\n"


def call(configuration, data):
    return subprocess.run(
        [os.path.expandvars(argument) for argument in configuration["peerCommand"]],
        input=data, stdout=subprocess.PIPE,
        check=True, timeout=configuration["timeout"],
    ).stdout


def pending_records(outbox):
    return outbox.glob("*.datom")


def deliver(configuration):
    signal = Path(configuration["wake"])
    signal.unlink(missing_ok=True)
    outbox = Path(configuration["outbox"])
    streams = configured_streams(configuration)
    for record in sorted(pending_records(outbox)):
        data = record.read_bytes()
        identity = read_publication(data, streams).digest()
        if record.name != identity + ".datom":
            raise ValueError("outbox name does not match publication")
        reply = call(configuration, data)
        if reply in REFUSALS:
            raise ValueError(reply.decode("ascii").strip())
        if reply != f"Accepted.{identity}\n".encode("ascii"):
            raise ValueError("Curriculum gave no matching durable admission")
        record.unlink()
        sync_directory(outbox)


def reconnect(configuration):
    Path(configuration["wake"]).unlink(missing_ok=True)
    if call(configuration, b"") != b"":
        raise ValueError("wake returned unexpected output")


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
        case _:
            raise ValueError("invalid publication operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
