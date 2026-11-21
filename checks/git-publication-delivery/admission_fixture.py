"""A controllable local consumer for transport-only checks."""

from pathlib import Path
import re
import socket
from threading import Thread


class AdmissionFixture:
    def __init__(self, root, inbox):
        self.address = Path(root) / "admit.sock"
        self.inbox = Path(inbox)
        self.refuse = False
        self.observed = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.address))
        self.listener.listen()
        Thread(target=self.run, daemon=True).start()

    def run(self):
        while True:
            request, _ = self.listener.accept()
            with request, request.makefile("rb") as stream:
                text = stream.read(4096)
                match = re.fullmatch(
                    rb"PublicationStored\.\{ ([0-9a-f]{64}) \{ \{ (\S+) (\S+) \} (\S+) (\S+) \} \}\n",
                    text,
                )
                if match is None:
                    request.sendall(b"Refused.Invalid\n")
                    continue
                identity, repository, reference, old, new = match.groups()
                canonical = b"{ " + b" ".join((repository, reference, old, new)) + b" }\n"
                durable_record = self.inbox / (identity.decode("ascii") + ".datom")
                if not durable_record.exists() or durable_record.read_bytes() != canonical:
                    request.sendall(b"Refused.Unavailable\n")
                    continue
                self.observed.append(identity)
                if self.refuse:
                    request.sendall(b"Refused.Unavailable\n")
                else:
                    request.sendall(b"Accepted." + identity + b"\n")
