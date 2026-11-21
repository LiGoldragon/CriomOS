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
def listener(binary, socket, admissions, uid, ready_marker):
    libc = ctypes.CDLL(None, use_errno=True)
    descriptor = libc.inotify_init1(os.O_CLOEXEC)
    assert descriptor >= 0
    assert libc.inotify_add_watch(descriptor, os.fsencode(ready_marker.parent), 0x100) >= 0
    process = subprocess.Popen(
        [binary, f"{{ {socket} {admissions} {uid} 2000 Some.{ready_marker} }}"], stderr=subprocess.PIPE
    )
    pidfd = os.pidfd_open(process.pid)
    try:
        ready, _, _ = select.select([descriptor, pidfd], [], [], 5)
        assert ready and pidfd not in ready, (
            process.stderr.read().decode() if pidfd in ready else "socket readiness timed out"
        )
        os.read(descriptor, 65536)
        assert socket.is_socket() and ready_marker.is_file()
        yield
    finally:
        process.terminate()
        process.communicate(timeout=5)
        os.close(pidfd)
        os.close(descriptor)
        socket.unlink(missing_ok=True)
        ready_marker.unlink(missing_ok=True)


receiver, binary, legacy = map(lambda path: Path(path).resolve(), sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="admit-proof-") as temporary:
    root = Path(temporary)
    outbox, admissions, runtime = (root / name for name in ("nondefault-spool", "admitted", "run"))
    for directory in (outbox, admissions, runtime):
        directory.mkdir()
    socket = runtime / "admit.sock"
    marker = root / "ready"
    readiness = root / "consumer-ready"
    readiness.mkdir()
    ready_marker = readiness / "marker"
    config = root / "delivery.json"
    invoke = [sys.executable, str(receiver), str(config)]
    config.write_text(json.dumps(dict(
        streams=[
            dict(repositoryName="test/belief", referenceName="refs/heads/main"),
            dict(repositoryName="test/belief", referenceName="refs/heads/release/v1"),
        ], outbox=str(outbox), wake=str(marker),
        timeout=5, admissionTimeout=3, curriculumEndpoint=str(socket),
        peerCommand=invoke + ["receive"],
    )))
    old, new = "1" * 40, "2" * 40
    flat = f"{{ test/belief refs/heads/main {old} {new} }}\n".encode()
    identity = hashlib.sha256(flat).hexdigest()
    name = identity + ".datom"
    legacy_config = root / "legacy.json"
    legacy_config.write_text(json.dumps(dict(
        repositories=["test/belief"], outbox=str(outbox), wake=str(marker),
    )))
    subprocess.run([sys.executable, str(legacy), str(legacy_config), "enqueue", "test/belief"],
                   input=f"{old} {new} refs/heads/main\n".encode(), check=True)

    def run(*args, data=b""):
        return subprocess.run(invoke + list(args), input=data, capture_output=True, timeout=8)

    failed = run("deliver")
    assert failed.returncode and b"Refused.Unavailable" in failed.stderr
    assert run("receive", data=flat).stdout == b"Refused.Unavailable\n"
    assert (outbox / name).read_bytes() == flat
    assert not list(admissions.iterdir())
    with listener(binary, socket, admissions, os.getuid() + 1, ready_marker):
        denied = run("deliver")
        assert denied.returncode and b"Refused.Untrusted" in denied.stderr
        assert run("receive", data=flat).stdout == b"Refused.Untrusted\n"
        assert (outbox / name).exists() and not list(admissions.iterdir())
    admitted = admissions / name
    with listener(binary, socket, admissions, os.getuid(), ready_marker):
        # The receiver admits, but the sender does not see this reply.
        forgotten_reply = run("receive", data=flat)
        assert forgotten_reply.stdout == f"Accepted.{identity}\n".encode()
        assert (outbox / name).read_bytes() == flat
        original = admitted.read_bytes()
        assert b"{ test/belief refs/heads/main }" in original
    with listener(binary, socket, admissions, os.getuid(), ready_marker):
        receiver_configuration = root / "reconnect.json"
        receiver_configuration.write_text(json.dumps(dict(
            wake=str(ready_marker), timeout=5, peerCommand=invoke + ["wake"],
        )))
        wake_reply = subprocess.run([sys.executable, str(receiver), str(receiver_configuration), "reconnect"],
                                    capture_output=True, timeout=8, check=True)
        assert not wake_reply.stdout and not ready_marker.exists() and marker.exists()
        replay = run("deliver")
        assert replay.returncode == 0, replay.stderr
        assert not list(outbox.iterdir())
        assert admitted.read_bytes() == original
        assert len(list(admissions.iterdir())) == 1
        ref = "refs/heads/release/v1"
        old256, new256 = "0" * 64, "b" * 64
        release = f"{{ test/belief {ref} {old256} {new256} }}\n".encode()
        release_id = hashlib.sha256(release).hexdigest()
        result = run("enqueue", "test/belief", data=f"{old256} {new256} {ref}\n".encode())
        assert result.returncode == 0, result.stderr
        queued, = outbox.iterdir()
        assert queued.name == f"{release_id}.datom" and queued.read_bytes() == release
        assert marker.exists()
        assert run("receive", data=release.replace(ref.encode(), b"refs/heads/unlisted")).stdout == b"Refused.Invalid\n"
        replay = run("deliver")
        assert replay.returncode == 0, replay.stderr
        assert not list(outbox.iterdir())
        assert (admissions / f"{release_id}.datom").is_file()
        assert len(list(admissions.iterdir())) == 2
    print("Real Curriculum admitted an exact non-main publication with SHA-256 object IDs.")
    print("A main record created by the pre-change sender survived its upgrade.")
    print("Real Curriculum: refusals retained the outbox; a lost admission reply survived consumer restart; its readiness woke replay, retired the sender record and kept one admission.")
