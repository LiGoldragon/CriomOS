"""Isolated OpenSSH witness; run as a user accepted by local sshd/PAM."""

import getpass
import hashlib
import json
from pathlib import Path
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile


protocol = Path(sys.argv[1]).resolve()
user = getpass.getuser()
with tempfile.TemporaryDirectory(prefix="publication-ssh-") as temporary:
    root = Path(temporary)
    with socket.socket() as address:
        address.bind(("127.0.0.1", 0))
        port = address.getsockname()[1]
    for name in ("host", "sender", "receiver", "untrusted"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
    known = root / "known"
    known.write_text(f"[127.0.0.1]:{port} " + (root / "host.pub").read_text())
    outbox, inbox = (root / name for name in ("outbox", "inbox"))
    outbox.mkdir()
    inbox.mkdir()
    marker = root / "ready"

    def client(key):
        return [
            "ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known}",
            "-o", "GlobalKnownHostsFile=/dev/null", "-T", "-i", str(root / key),
            "-p", str(port), "-l", user, "127.0.0.1",
        ]

    def endpoint(role, key):
        config = root / f"{role}.json"
        config.write_text(json.dumps(dict(
            repositories=["test/belief"], outbox=str(outbox), inbox=str(inbox),
            wake=str(marker), timeout=5, peerCommand=client(key),
        )))
        return [sys.executable, str(protocol), str(config)]

    sender = endpoint("sender", "sender")
    receiver = endpoint("receiver", "receiver")
    (root / "authorized_keys").write_text("".join(
        f'restrict,command="{shlex.join(command)}" ' + (root / f"{key}.pub").read_text()
        for key, command in (("sender", receiver + ["receive"]), ("receiver", sender + ["wake"]))
    ))
    configuration = root / "sshd.conf"
    configuration.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'host'}
AuthorizedKeysFile {root / 'authorized_keys'}
AllowUsers {user}
StrictModes no
UsePAM yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PidFile {root / 'sshd.pid'}
""")
    daemon = subprocess.Popen(
        [shutil.which("sshd"), "-D", "-e", "-f", str(configuration)],
        stderr=subprocess.PIPE,
    )
    try:
        assert select.select([daemon.stderr], [], [], 5)[0], "test sshd did not announce readiness"
        line = daemon.stderr.readline()
        assert b"Server listening" in line, line.decode()
        old, new = "0" * 40, "1" * 40
        update = f"{old} {new} refs/heads/main\n".encode()
        data = f"{{ test/belief refs/heads/main {old} {new} }}\n".encode()
        identity = hashlib.sha256(data).hexdigest()
        subprocess.run(sender + ["enqueue", "test/belief"], input=update, check=True)
        denied = subprocess.run(client("untrusted"), input=data, capture_output=True, timeout=5)
        assert denied.returncode and not list(inbox.iterdir())
        marker.unlink()
        subprocess.run(receiver + ["reconnect"], check=True)
        assert marker.exists()
        subprocess.run(sender + ["deliver"], check=True)
        assert not list(outbox.iterdir())
        assert (inbox / f"{identity}.datom").read_bytes() == data
        # The key's fixed receiver command takes precedence over a client's command.
        forced = subprocess.run(client("sender") + ["printf unrelated"], input=data, capture_output=True, check=True)
        assert forced.stdout == f"Stored.{identity}\n".encode()
        assert len(list(inbox.iterdir())) == 1
        print("OpenSSH loopback: untrusted key refused; pinned peers stored, acknowledged, and woke replay via restricted commands.")
    finally:
        daemon.terminate()
        daemon.communicate(timeout=5)
