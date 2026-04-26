# Rust shelling stack for lojix-cli — research

Triggered by the silent-build bug we just fixed (`Command::output()`
buffers both streams). The fix unblocks the immediate problem but
points at a bigger question: what's the right shelling/orchestration
stack as lojix-cli grows toward parallel multi-node builds (some
local, some on remote builders).

Findings below are from training-corpus knowledge (no web verification
this turn — Jan 2026 cutoff). Maintenance status should be re-checked
before adopting.

## Async local subprocess

| Library | Verdict |
|---|---|
| **`tokio::process::Command`** (built-in) | **Substrate.** `Stdio::piped` + `BufReader::lines()` over child stdout/stderr; integrates natively with the actor model already in use. Verbose for cancellation/reaper semantics — that's what the next layer adds. |
| `async-process` (smol) | Skip — runtime-agnostic but you're already on tokio. |
| `duct` | Skip for the orchestrator core (sync, async fork unmaintained). Fine for one-shot helpers. |
| `xshell` (matklad) | Skip — sync, capture-by-default, build-script ergonomics, wrong shape for live streaming. |
| **`process-wrap` / `command-group`** | **Use it.** Process-group spawn so a Ctrl-C / drop kills the whole `nix build` tree instead of orphaning helpers. Tiny crate, complements `tokio::process`. The same author also ships `tokio-command-group`; `process-wrap` is the unified modern pick. |

## Remote / SSH

| Library | Verdict |
|---|---|
| **`openssh`** (jonhoo) | **The answer for lojix.** Wraps the system `ssh` binary using **OpenSSH ControlMaster multiplexing** — reused sessions cost ~nothing. Async, tokio-native, `Session::command()` returns a `tokio::process::Child`-shaped thing → *the same streaming code path as local*. Active. |
| `russh` (Eugeny) | Skip — pure-Rust SSH-2 is great but you'd reimplement keepalive, agent-forwarding, known_hosts. Worth it only when `ssh` isn't on the client (irrelevant here). |
| `async-ssh2-tokio` / `ssh2` | Skip — libssh2 FFI, sparser maintenance, awkward streaming. |
| `thrussh` | Abandoned (succeeded by russh). |

Reference: `nixos-rebuild --target-host`, `colmena`, `deploy-rs` all
exec the `ssh` CLI directly. `openssh` formalises that pattern with
free multiplexing.

## Job orchestration in actor systems

| Primitive | Use |
|---|---|
| **`tokio::task::JoinSet`** (built-in) | The right "spawn N node-build jobs, await whichever finishes next" primitive. Strictly better than `FuturesUnordered<JoinHandle<_>>` because of abort-on-drop. |
| **`tokio::sync::Semaphore`** (built-in) | Cap concurrency per remote host (one ControlMaster session, but parallel commands within budget). |
| **`ractor`** (already in deps) | One `BuildSupervisor` spawns one `NodeBuildActor` per target; each child owns its `tokio::process::Child` (or `openssh::Session::command()`) and forwards `BuildEvent { node, line, stream }` to a single `OutputActor`. Cancellation/retry/progress live inside the actor, not threaded through callbacks. |

## Output multiplexing / progress

| Library | Verdict |
|---|---|
| **`indicatif`** (mitsuhiko) | **Use it.** De-facto standard. `MultiProgress` gives one bar per node; `ProgressBar::suspend()` lets you `println` cleanly between redraws. Used by cargo, uv, rustup. |
| **`tracing` + `tracing-subscriber`** | **Use it.** Structured logs with per-span fields (`node="ouranos"`). |
| **`tracing-indicatif`** | The bridge. Renders log lines *above* live progress bars without tearing. |
| `ratatui` / nu-cli live tables | Overkill — revisit only if you want a TUI dashboard mode later. |

## Recommended stack for lojix-cli

```
tokio::process::Command                  ← substrate
  + process-wrap                          ← process-group kill cascade
  + openssh                               ← remote, with ControlMaster reuse
orchestrated by:
  ractor (NodeBuildActor + OutputActor)  ← already in lojix-cli
  + tokio::task::JoinSet                  ← parallel jobs
  + tokio::sync::Semaphore                ← per-host concurrency cap
rendered via:
  indicatif::MultiProgress
  + tracing + tracing-indicatif           ← log lines render above bars
```

### Concrete shape

A `NodeBuildActor` per target owns a `Child` (local) or
`openssh::Session::command()` (remote) — *same trait surface either
way*; both expose tokio `AsyncRead` stdout/stderr. The actor reads
lines, tags them with its node name, captures the final-result line
for parsing, and emits `BuildEvent` messages to a single
`OutputActor` that owns the `MultiProgress`.

### Why this stack

- ControlMaster makes "5 commands to ouranos" cost one
  TCP+auth handshake — the SSH equivalent of the
  `output()`→`spawn()` fix that just landed: stop paying setup cost
  per call.
- Local and remote share one trait surface (`AsyncRead`) — the actor
  body doesn't care.
- `JoinSet` + `Semaphore` give you parallelism + back-pressure with
  zero new deps.
- `tracing-indicatif` is what other modern Rust CLIs (uv, jj-style)
  converge on for "live progress + structured logs in the same
  terminal."

This stack is what `colmena`, `deploy-rs`, and modern `nixos-rebuild`
workflows converge on, minus the ad-hoc shell glue.

## Migration order — snapshot

| Step | Status | Where |
|---|---|---|
| 1. `tokio::process` + `process-wrap` (kill cascade) | **DONE** | [lojix-cli 0b085794](https://github.com/LiGoldragon/lojix-cli/commit/0b085794) |
| 2. Remote builds via `openssh` | **STUBBED** | [54f50b1c](https://github.com/LiGoldragon/lojix-cli/commit/54f50b1c) — `BuildLocation::Remote { host }` returns `NotImplemented` |
| 3. Per-target ractor + `JoinSet` | **DEFERRED** | — |
| 4. `indicatif::MultiProgress` + `tracing-indicatif` | **DEFERRED** | — |

The durable design rationale (why parallelism is the daemon's job
not the client's; why remote-build has two meanings and nix's own
`buildMachines` may obviate openssh-from-lojix) lives in
[lojix-cli/ARCHITECTURE.md §"Build orchestration model"](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md).
This report is a snapshot; the contract lives in the code's repo.
