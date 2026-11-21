"""Exercise durable delivery through a real Git accept, with a controllable peer."""

import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

from admission_fixture import AdmissionFixture


protocol = Path(sys.argv[1])
python = sys.executable
root = Path.cwd()
outbox, signal = (root / name for name in ("nondefault-spool", "signal"))
for directory in (outbox, signal):
    directory.mkdir()
marker = signal / "ready"
consumer = AdmissionFixture(root)
streams = [
    dict(repositoryName="sample/psyche", referenceName="refs/heads/main"),
    dict(repositoryName="sample/psyche", referenceName="refs/heads/release/v1"),
    dict(repositoryName="sample/mind", referenceName="refs/heads/main"),
]
configuration = root / "route.json"
configuration.write_text(json.dumps(dict(
    streams=streams, wake=str(marker), outbox=str(outbox),
    admissionTimeout=5, curriculumEndpoint=str(consumer.address),
    timeout=5, peerCommand=[python, str(root / "peer.py")],
)))
route = [python, str(protocol), str(configuration)]
mode = root / "peer-mode"
(root / "peer.py").write_text(f"""
from pathlib import Path
import subprocess
import sys

mode = Path({str(mode)!r}).read_text()
data = sys.stdin.buffer.read()
if mode == "offline":
    sys.exit(1)
if mode == "wrong":
    print("Accepted." + "f" * 64)
    sys.exit(0)
command = {route!r} + ["receive" if data else "wake"]
result = subprocess.run(command, input=data, capture_output=True, check=True)
if mode != "drop":
    sys.stdout.buffer.write(result.stdout)
""")


def run(*arguments, data=b"", ok=True):
    child = subprocess.run(route + list(arguments), input=data, capture_output=True, timeout=10)
    assert (child.returncode == 0) == ok, (arguments, child.stderr)
    return child.stdout


def git(directory, *arguments):
    return subprocess.check_output(["git", "-C", str(directory), *arguments], stderr=subprocess.PIPE).strip()


sender, remote = root / "work", root / "bare"
for directory in (sender, remote):
    directory.mkdir()
git(sender, "init", "-b", "main")
git(remote, "init", "--bare")
hook = remote / "hooks" / "post-receive"
hook.write_text("#!" + shutil.which("sh") + "\nexec " + shlex.join(route + ["enqueue", streams[0]["repositoryName"]]) + "\n")
hook.chmod(0o700)
git(sender, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "commit", "--allow-empty", "-m", "previous main")
git(sender, "push", str(remote), "main")
mode.write_text("ready")
run("deliver")
assert not list(outbox.iterdir()) and not marker.exists()
old = git(sender, "rev-parse", "HEAD")
git(sender, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "commit", "--allow-empty", "-m", "next main")
new = git(sender, "rev-parse", "HEAD")
git(sender, "merge-base", "--is-ancestor", old.decode(), new.decode())
git(sender, "push", str(remote), "main", "HEAD:refs/heads/topic")
assert git(remote, "rev-parse", "refs/heads/main") == new

data = b"{ sample/psyche refs/heads/main " + old + b" " + new + b" }\n"
identity = hashlib.sha256(data).hexdigest()
name = identity + ".datom"
assert [item.name for item in outbox.iterdir()] == [name]
assert (outbox / name).read_bytes() == data and marker.exists()
run("enqueue", "sample/unconfigured", data=old+b" "+new+b" refs/heads/main\n")
assert [item.name for item in outbox.iterdir()] == [name]

for failure in ("offline", "wrong", "drop"):
    mode.write_text(failure)
    run("deliver", ok=False)
    assert (outbox / name).read_bytes() == data
    assert not marker.exists()
mode.write_text("ready")
consumer.refuse = True
run("deliver", ok=False)
assert (outbox / name).read_bytes() == data
assert consumer.observed[-1] == identity.encode()
consumer.refuse = False
run("reconnect")
assert marker.exists()
run("deliver")
assert not list(outbox.iterdir()) and not marker.exists()
assert run("receive", data=data) == f"Accepted.{identity}\n".encode()
assert run("receive", data=data.replace(b"sample/psyche", b"sample/unconfigured")) == b"Refused.Invalid\n"
assert run("receive", data=data.replace(b"refs/heads/main", b"refs/heads/topic")) == b"Refused.Invalid\n"
assert run("receive", data=b"invalid") == b"Refused.Invalid\n"
assert not run("wake", data=b"invalid", ok=False)
assert run("wake") == b""
marker.unlink()
assert not marker.exists()
release_ref = b"refs/heads/release/v1"
git(sender, "push", str(remote), f"HEAD:{release_ref.decode()}")
assert git(remote, "rev-parse", release_ref.decode()) == new
release = b"{ sample/psyche " + release_ref + b" " + b"0" * len(new) + b" " + new + b" }\n"
release_id = hashlib.sha256(release).hexdigest()
queued, = outbox.iterdir()
assert queued.name == release_id + ".datom" and queued.read_bytes() == release and marker.exists()
run("enqueue", "sample/mind", data=old + b" " + new + b" " + release_ref + b"\n")
run("enqueue", "sample/psyche", data=old + b" " + new + b" refs/heads/unlisted\n")
assert list(outbox.iterdir()) == [queued]
assert run("receive", data=release.replace(b"sample/psyche", b"sample/mind")) == b"Refused.Invalid\n"
run("deliver")
assert consumer.observed[-1] == release_id.encode()
assert not list(outbox.iterdir()) and not marker.exists()
print("Exact main and non-main Git stream delivery, pair filtering, retained outbox, reconnect and deduplication passed.")
