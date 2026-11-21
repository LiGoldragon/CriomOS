"""A controllable local consumer for transport-only checks."""

import hashlib
from pathlib import Path
import re
import socket
from threading import Thread


class AdmissionFixture:
    def __init__(self, root):
        self.address = Path(root) / "admit.sock"
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
                    rb"PublicationReceived\.\{ \{ (\S+) (\S+) \} (\S+) (\S+) \}\n",
                    text,
                )
                if match is None:
                    request.sendall(b"Refused.Invalid\n")
                    continue
                canonical = b"{ " + b" ".join(match.groups()) + b" }\n"
                identity = hashlib.sha256(canonical).hexdigest().encode("ascii")
                self.observed.append(identity)
                if self.refuse:
                    request.sendall(b"Refused.Unavailable\n")
                else:
                    request.sendall(b"Accepted." + identity + b"\n")
