# Handover — 2026-04-28 (evening continuation of 0028)

Picker-up document for an agent with clean context. Continues from
[`0028`](./0028-handover-2026-04-28.md), which captured the morning's
nota-codec migration + first end-to-end deploy at gen 76. This report
covers the evening's hexis bootstrap → Chrome integration → lojix-cli
self-escalation arc.

## Headline

**Ouranos is at systemd-boot default = gen 80, awaiting reboot.** Gen 80
is CriomOS [`b0b868fa`](https://github.com/LiGoldragon/CriomOS/commit/b0b868fa)
which pulls hexis [`8ef02c41`](https://github.com/LiGoldragon/hexis/commit/8ef02c41)
through and wraps `pkgs.google-chrome` with `inputs.hexis.lib.wrapWithHexis`
seeding `/devtools/remote_debugging/user-enabled = true` in `Local State`
(once-mode). Live ouranos still on gen 75 (archive) until clean reboot.

## What landed today (since 0028)

### hexis: v0 scaffold → v0.1 functional reconciler

New repo at [`github:LiGoldragon/hexis`](https://github.com/LiGoldragon/hexis)
([`8ef02c41`](https://github.com/LiGoldragon/hexis/commit/8ef02c41)).
Design report 0029 was written, durable substance migrated into the
repo's `ARCHITECTURE.md` + `ARCHITECTURE-DEFERRED.md`, then 0029 deleted
per AGENTS.md "delete superseded — don't banner."

v0.1 is **functionally complete** for the local-single-file reconcile path:

- **Three states per managed file**: declared (Nix overlay), snapshot
  (hexis-owned, at `~/.local/state/hexis/snapshot/<file_id>.json`),
  live (the user/app's file).
- **Three per-key modes** dispatched leaf-by-leaf via nearest-ancestor
  lookup: `once` (seed at first apply, mark, never touch again),
  `ensure` (default — declared wins where it speaks, drift survives
  where declared is silent), `always` (declared asserted every pass).
- **Four-step apply** (`Read → Plan → Apply → Commit`) wired
  synchronously in `State::apply` (not a self-cast chain — that's v2;
  see `ARCHITECTURE-DEFERRED.md` § "v0.1 vs v2 phase observability").
- **RFC 7396 drift** computed `between(snapshot.image, live.data)` on
  every apply with a non-null prior snapshot (skipped on first run).
  Persisted as a rotating journal at `<drift_dir>/<file_id>.json`,
  last 30 entries.
- **Atomic IO** via `tempfile + persist` for live + snapshot + drift;
  advisory `flock(LOCK_EX)` over the apply window via `fs2`.
- **Actor topology** (ractor): `Supervisor` (root) spawns linked
  per-target `Reconciler`s + a stub `Proposer`. v0.1 CLI bypasses
  the actor harness for the single-shot `hexis apply`; the actor
  wiring is exercised by a smoke test in `tests/scaffold.rs` and
  comes online in v2 for watcher-driven multi-target flows.
- **HM helper**: `inputs.hexis.lib.mkManagedConfig { file, declared,
  modes, hexis, pkgs, lib }` produces a `lib.hm.dag.entryAfter
  [ "writeBoundary" ]` activation entry. Replaces the broken
  `criomos-lib.mkJsonMerge` shallow-merge — vscodium's
  `mergeVscodiumSettings` already swapped over.
- **Pre-launch wrapper helper**: `inputs.hexis.lib.wrapWithHexis`
  produces a `pkgs.symlinkJoin` derivation that wraps an upstream
  binary with `wrapProgram --run`. The `--run` body checks `pgrep -x
  <processName>`; if no instance is running, runs `hexis apply`
  before `exec`-ing the real binary. Used for apps that own their
  config at runtime (Chrome's `Local State`).

89 tests pass (smoke + types + declared + live + snapshot + drift +
plan + reconciler-integration). `nix flake check` green.

Style-guide consequence: **`## No ZST method holders`** rule landed in
[`tools-documentation/rust/style.md`](https://github.com/LiGoldragon/tools-documentation/blob/main/rust/style.md)
([`ca54c835`](https://github.com/LiGoldragon/tools-documentation/commit/ca54c835)) — bans
`pub struct Foo;` with inherent methods doing real work as concealed
free-functions. Triggered the Reconciler/Supervisor refactor in hexis
([`4f850bbc`](https://github.com/LiGoldragon/hexis/commit/4f850bbc)):
work moved off the ZSTs onto data-bearing `State` /
`SupervisorHandle`; ZSTs now hold only the Actor trait impl.

### Chrome 144 MCP autoConnect via hexis

The original ask that started the whole hexis arc — "Allow remote
debugging for this browser instance" toggle at
`chrome://inspect/#remote-debugging`. Discovery (Chrome closed; diff
`Local State` before/after the toggle) yielded:

- **File**: `~/.config/google-chrome/Local State` (Chrome's global
  state, *not* per-profile `Default/Preferences`).
- **Pointer**: `/devtools/remote_debugging/user-enabled`.
- **Value**: `true`.

Wired in CriomOS-home [`9cebd425`](https://github.com/LiGoldragon/CriomOS-home/commit/9cebd425):
`programs.chromium.package = inputs.hexis.lib.wrapWithHexis { ... }`
in [`profiles/max/default.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/modules/home/profiles/max/default.nix).
`processName = "chrome"` (not `"google-chrome"` — that's the launcher
shim; the actual Chrome process is `chrome`).

After ouranos reboots: first launch via the wrapped binary → no
existing `chrome` process → `hexis apply` runs → `Plan::build` emits
`WriteOnce` (no marker yet) → `Local State` gets the seed + snapshot
records the marker → wrapper `exec`s real Chrome → toggle is on,
`Server running at: 127.0.0.1:9222`. Subsequent launches: marker
present → `LeaveAlone` → user owns the toggle.

### lojix-cli: ssh-root@localhost escalation built in

Was: `lojix-cli deploy --action boot|switch|test` failed with
`Permission denied` on `/nix/var/nix/profiles/system` from a user
shell. Workaround was `ssh root@localhost lojix-cli ...`, but that
projected to `/root/.cache/lojix/` instead of the user's cache.

Now ([`0336625c`](https://github.com/LiGoldragon/lojix-cli/commit/0336625c)):
projection + build run as user (cache locality preserved); the
privileged tail (`nixos-rebuild boot|switch|test`) is automatically
re-invoked through `ssh -o BatchMode=yes root@localhost <quoted
command>`. New private `ShellWord` newtype handles the
single-string-after-host argv reparsing.

Per Li 2026-04-28: *"we don't use sudo, we use ssh root. That should
be built in to lojix-cli."* It is now. **Don't `sudo lojix-cli`** —
that defeats user-side cache reuse.

Hardcoded ssh-host = `localhost` for now; cross-node deploys (e.g.,
`--node zeus` from `ouranos`) still need the user to run lojix-cli
*on the target node*. Tracked in `bd CriomOS-4yt` orbit; fix is
horizon-derived addressing.

### Audit pass + small fixes

Deep audit across hexis / lojix-cli / CriomOS-home / CriomOS / tools-
documentation surfaced 5 small drifts (all fixed in the same arc):

- `lojix-cli/README.md` listed a `watch` subcommand that doesn't exist — dropped.
- `hexis/README.md` "v0.1 — scaffolding, no logic" was stale — now reflects working four-step apply.
- `hexis/ARCHITECTURE.md` Phase enum description still listed
  `Loaded/Planned/Applied` variants the code dropped — synced to
  `Idle | Committed | Failed(String)`, with v2 self-cast plan
  preserved as forward-pointer.
- `lojix-cli/Cargo.toml` missing `license-file` + `repository` — added; `LICENSE.md` (License of Non-Authority) copied from brightness-ctl.
- `lojix-cli/src/build.rs` `BuildLocation::Remote` doc-comment said "currently only Local is wired" — confusing now that ssh-root *is* wired (different code path); clarified.

### Doc: tools-documentation/lojix-cli/basic-usage.md

New agent-facing usage doc ([`1d1f5a0f`](https://github.com/LiGoldragon/tools-documentation/commit/1d1f5a0f)):
five-action matrix, ssh-root behaviour, `--criomos` rev-pinning rule,
dbus-broker switch-inhibitor caveat, recovery via systemd-boot menu,
common patterns, pitfalls. Tone matches `jj/basic-usage.md` etc.
CriomOS `AGENTS.md` tool-references list updated to include `lojix-cli`.

## Open issues / pending

Authoritative in beads: `bd ready`, `bd list --status=open`. Today's
state:

- **`CriomOS-4ei` (P2) — ouranos reboot validation.** Boot loader
  default is gen 80; reboot to land. systemd-boot menu lets fall back
  to gen 75 (archive) or gen 76 (yesterday's first-touch deploy)
  if anything breaks.
- `CriomOS-bb5` (P2, in_progress) — hexis side-repo. v0.1 is shipped;
  this issue tracks v2 (proposal loop, watcher actor, TOML/YAML
  format coverage, cross-node drift sync via nota, conditional modes).
- `CriomOS-4yt` (P2) — lojix-cli `--home-only` deploy mode (no
  system rebuild, just HM). Distinct from the ssh-root escalation
  fix that just landed.
- `CriomOS-ng7` (P3) — prom + zeus `--action boot` deploy, once
  ouranos is validated. Now trivially achievable from ouranos via
  the new lojix-cli (assuming SSH-key auth to those nodes' root).
- `CriomOS-rh8` (P3) — goldragon datom coordinate gaps (nordvpn,
  wireguard, headscale `None` for ouranos vs maisiliym's real
  values). Pre-reboot decision still useful.
- `CriomOS-kwr` (P3, bug) — ouranos stale Qwen drv refs.
- `CriomOS-0ok` (P4) — codium gemini extension patchelf for
  cloudcode_cli ETXTBSY; dropped from extensions until then.
- `CriomOS-t50` (P4) — lojix-cli orchestration steps 3+4 (per-target
  ractor + tracing-indicatif).
- Pre-existing: `CriomOS-1ey` (security audit, P2), `CriomOS-4xw`
  (criomos-hw-scan, P3), `CriomOS-og4` (ROADMAP.md fate, P3).

`CriomOS-9qg` (lojix-cli ssh-root escalation) **closed** today
along with implementation in [`0336625c`](https://github.com/LiGoldragon/lojix-cli/commit/0336625c).

## Quick-reference: deploying with the new lojix-cli

From a normal user shell on the target node — **no sudo, no manual ssh wrap**:

```bash
rev=$(jj log -r main --no-graph --template 'commit_id' -n1 \
      --repo ~/git/CriomOS 2>/dev/null \
      || git -C ~/git/CriomOS rev-parse main)

lojix-cli deploy --cluster goldragon --node ouranos \
  --source ~/git/goldragon/datom.nota \
  --action boot \
  --criomos github:LiGoldragon/CriomOS/$rev
```

`--action test` is still blocked on the new criomos by the dbus →
dbus-broker switch inhibitor (per 0028); use `boot` and reboot.

If you find lojix-cli not on PATH, build directly:
`nix build /home/li/git/lojix-cli#default --print-out-paths`,
then call `<path>/bin/lojix-cli ...`.

## Where to read each area

- **hexis** — code at [`github:LiGoldragon/hexis`](https://github.com/LiGoldragon/hexis);
  v0.1 contracts in `ARCHITECTURE.md`; deferred v2 design in
  `ARCHITECTURE-DEFERRED.md`. The original 0029 design report was
  deleted on migration; substance survives in those two docs.
- **lojix-cli** — code at [`github:LiGoldragon/lojix-cli`](https://github.com/LiGoldragon/lojix-cli);
  internal architecture in `ARCHITECTURE.md`; **agent-facing usage
  rules in [`tools-documentation/lojix-cli/basic-usage.md`](https://github.com/LiGoldragon/tools-documentation/blob/main/lojix-cli/basic-usage.md)** —
  start here for any deploy work.
- **No ZST method holders rule** — [`tools-documentation/rust/style.md`
  § "No ZST method holders"](https://github.com/LiGoldragon/tools-documentation/blob/main/rust/style.md).
  Diagnostic shape: ZST + inherent methods doing real work →
  the noun is missing; step back, find the data-bearing type.
- **Chrome integration call site** — [`CriomOS-home/modules/home/profiles/max/default.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/modules/home/profiles/max/default.nix#L52-L82).
- **horizon-rs schema** — [`horizon-rs/lib/src/proposal.rs`](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/proposal.rs)
  for `NodeProposal` (carries `online: Option<bool>` +
  `nb_of_build_cores: Option<u32>` from yesterday's work).
- **nota-codec API** — [`nota-codec/README.md`](https://github.com/LiGoldragon/nota-codec/blob/main/README.md).
- **goldragon datom** — `~/git/goldragon/datom.nota`.
- **Distributed-builds wiring** — [`criomos-archive/docs/DISTRIBUTED_BUILDS.md`](https://github.com/LiGoldragon/criomos-archive/blob/main/docs/DISTRIBUTED_BUILDS.md).

## Sharp edges to know

- **Chrome must be closed when first launched via the wrapped
  binary** for the `once`-mode seed to take. The wrapper's
  `pgrep -x chrome` guard skips hexis-apply if Chrome is already up
  (avoiding race against in-memory `Local State`); first launch
  after reboot is the seed window. Subsequent launches no-op via
  the marker.
- **Marker is keyed by `FileId::from_path(<live_path>)`** — a
  12-char hash of the path. Same path → same file_id → same
  snapshot directory under `~/.local/state/hexis/snapshot/`. Delete
  that file to reset the once-mode seed.
- **prom's nix cache (`http://nix.prometheus.goldragon.criome`) is
  offline** — `warning: unable to download .../nix-cache-info`
  during deploys is benign; nix falls back to `cache.nixos.org`.
- **lojix-cli's ssh-root escalation needs SSH-key auth into
  `root@localhost`.** CriomOS sets this up by default; verify via
  `ssh -o BatchMode=yes root@localhost true`. If it fails, the
  deploy hits a password prompt and stalls.
- **Don't `sudo lojix-cli`** — defeats user-side cache reuse and is
  no longer needed since the escalation is built in.
