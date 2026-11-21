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
    outbox, inbox, admissions, runtime = (root / name for name in ("out", "in", "admitted", "run"))
    for directory in (outbox, inbox, admissions, runtime):
        directory.mkdir()
    socket = runtime / "admit.sock"
    marker = root / "ready"
    config = root / "delivery.json"
    invoke = [sys.executable, str(receiver), str(config)]
    config.write_text(json.dumps(dict(
        repositories=["test/belief"], outbox=str(outbox), inbox=str(inbox), wake=str(marker),
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
    assert failed.returncode and b"Stored." not in failed.stdout
    assert (outbox / name).read_bytes() == (inbox / name).read_bytes() == flat
    assert not list(admissions.iterdir())
    with listener(binary, socket, admissions, os.getuid() + 1):
        denied = run("deliver")
        assert denied.returncode and b"Stored." not in denied.stdout
        assert (outbox / name).exists() and not list(admissions.iterdir())
    with listener(binary, socket, admissions, os.getuid()):
        replay = run("deliver")
        assert replay.returncode == 0, replay.stderr
        assert not list(outbox.iterdir())
        admitted = admissions / name
        original = admitted.read_bytes()
        assert b"{ test/belief refs/heads/main }" in original
        duplicate = run("receive", data=flat)
        assert duplicate.returncode == 0 and duplicate.stdout == f"Stored.{identity}\n".encode()
        assert admitted.read_bytes() == original
        assert len(list(admissions.iterdir())) == 1
    print("Real Curriculum: offline and wrong-UID handoffs retained both records; matching admission retired the sender record; replay stored one admission.")
