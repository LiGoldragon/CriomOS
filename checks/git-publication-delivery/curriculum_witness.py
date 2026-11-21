"""Cross-repo witness against the real Curriculum admission binary."""

from contextlib import contextmanager
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile


@contextmanager
def listener(binary, socket, admissions, uid):
    libc = ctypes.CDLL(None, use_errno=True)
    descriptor = libc.inotify_init1(os.O_CLOEXEC)
    assert descriptor >= 0
    assert libc.inotify_add_watch(descriptor, os.fsencode(socket.parent), 0x100) >= 0
    process = subprocess.Popen(
        [binary, f"{{ {socket} {admissions} {uid} 2000 }}"], stderr=subprocess.PIPE
    )
    pidfd = os.pidfd_open(process.pid)
    try:
        ready, _, _ = select.select([descriptor, pidfd], [], [], 5)
        assert ready and pidfd not in ready, (
            process.stderr.read().decode() if pidfd in ready else "socket readiness timed out"
        )
        os.read(descriptor, 65536)
        assert socket.is_socket()
        yield
    finally:
        process.terminate()
        process.communicate(timeout=5)
        os.close(pidfd)
        os.close(descriptor)
        socket.unlink(missing_ok=True)


receiver, binary = map(lambda path: Path(path).resolve(), sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="admit-proof-") as temporary:
    root = Path(temporary)
    outbox, admissions, runtime = (root / name for name in ("out", "admitted", "run"))
    for directory in (outbox, admissions, runtime):
        directory.mkdir()
    socket = runtime / "admit.sock"
    marker = root / "ready"
    config = root / "delivery.json"
    invoke = [sys.executable, str(receiver), str(config)]
    config.write_text(json.dumps(dict(
        repositories=["test/belief"], outbox=str(outbox), wake=str(marker),
        timeout=5, admissionTimeout=3, curriculumEndpoint=str(socket),
        peerCommand=invoke + ["receive"],
    )))
    old, new = "1" * 40, "2" * 40
    flat = f"{{ test/belief refs/heads/main {old} {new} }}\n".encode()
    identity = hashlib.sha256(flat).hexdigest()
    name = identity + ".datom"
    subprocess.run(invoke + ["enqueue", "test/belief"],
                   input=f"{old} {new} refs/heads/main\n".encode(), check=True)

    def run(*args, data=b""):
        return subprocess.run(invoke + list(args), input=data, capture_output=True, timeout=8)

    failed = run("deliver")
    assert failed.returncode and b"Refused.Unavailable" in failed.stderr
    assert run("receive", data=flat).stdout == b"Refused.Unavailable\n"
    assert (outbox / name).read_bytes() == flat
    assert not list(admissions.iterdir())
    with listener(binary, socket, admissions, os.getuid() + 1):
        denied = run("deliver")
        assert denied.returncode and b"Refused.Untrusted" in denied.stderr
        assert run("receive", data=flat).stdout == b"Refused.Untrusted\n"
        assert (outbox / name).exists() and not list(admissions.iterdir())
    admitted = admissions / name
    with listener(binary, socket, admissions, os.getuid()):
        # The receiver admits, but the sender does not see this reply.
        forgotten_reply = run("receive", data=flat)
        assert forgotten_reply.stdout == f"Accepted.{identity}\n".encode()
        assert (outbox / name).read_bytes() == flat
        original = admitted.read_bytes()
        assert b"{ test/belief refs/heads/main }" in original
    with listener(binary, socket, admissions, os.getuid()):
        replay = run("deliver")
        assert replay.returncode == 0, replay.stderr
        assert not list(outbox.iterdir())
        assert admitted.read_bytes() == original
        assert len(list(admissions.iterdir())) == 1
    print("Real Curriculum: refusals retained the outbox; a lost admission reply survived consumer restart; replay retired the sender record and kept one admission.")
