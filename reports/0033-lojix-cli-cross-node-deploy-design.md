# lojix-cli — own the deploy pipeline; `--builder` selects build host

Tracked in `bd CriomOS-6az`. Field-deploy gates `bd CriomOS-ng7`
(prom + zeus).

## What changes

`lojix-cli` stops calling `nixos-rebuild` and stops hardcoding
`ssh root@localhost`. Instead it owns the privileged tail as three
explicit primitives, all derived from horizon truth:

```
nix build  →  nix copy  →  ssh + switch-to-configuration
```

A new `--builder <NodeName>` flag picks where `nix build` runs.
The deploy *target* is always `--node` — the projection viewpoint
*is* the deployment subject; fragmenting them would violate the
[GUIDELINES.md "names are commitments"](../docs/GUIDELINES.md#naming-is-a-semantic-layer)
discipline.

## Why not nixos-rebuild

`nixos-rebuild boot|switch` bundles the build, closure-copy, and
activation primitives behind one subprocess. That bundling is
exactly what forced the `--build-host` flag question into the
earlier draft of this design — the flag only exists to give
nixos-rebuild *its* opinion about where the build runs, when we
need to drive that decision ourselves anyway.

The three primitives nixos-rebuild bundles are each a one-liner
we already understand and partly own:

1. `nix build <flake>#nixosConfigurations.target.config.system.build.toplevel --no-link --print-out-paths` (the existing `Build` action does this verbatim)
2. `nix copy --to ssh-ng://root@<target> <store-path>` (or `--from … --to …` when the builder is third-party)
3. `ssh root@<target> "[nix-env -p /nix/var/nix/profiles/system --set <closure>] && <closure>/bin/switch-to-configuration <action>"`

Owning them dissolves the open question about `--build-host` and
local `--override-input path:` interaction, and makes `--builder`
first-class across all five actions instead of just three. The
[`bd CriomOS-ng7`](.) plan-of-record for prom is already this same
sequence done by hand — the operator was routing around
nixos-rebuild because the manual path is simpler.

## Two axes, both in the horizon already

| axis | concept | source of truth |
|---|---|---|
| **target** | which node's `/nix/var/nix/profiles/system` + bootloader is mutated | `horizon.node.criomeDomainName` (the projection's viewpoint) |
| **builder** | which node runs `nix build` for the closure | `horizon.exNodes.<n>.criomeDomainName` for the chosen builder, gated by `is_builder && online` |

Both addresses come from `criome_domain_name`
([horizon-rs/lib/src/node.rs:45](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/node.rs#L45)).
No schema change needed.

## CLI surface

```
lojix-cli {deploy|build|eval} \
  --cluster <C> --node <N> \
  --source <path> \
  [--criomos <flake>] \
  [--action <eval|build|boot|switch|test>] \
  [--builder <NodeName>]
```

| flag | meaning | default |
|---|---|---|
| `--node <name>` | projection viewpoint = deploy target | required |
| `--builder <name>` | sibling node that runs `nix build`; must be `is_builder && online` | absent → build on dispatcher |

`--builder` accepts a `NodeName`, not an ssh string. Resolution to
`<n>.<cluster>.criome` is internal.

## Pipeline by action

| action | build phase | copy phase | activate phase |
|---|---|---|---|
| `Eval` | `nix eval --raw …drvPath` (locally; if `--builder`, stage + ssh + run there) | — | — |
| `Build` | `nix build …` (locally; if `--builder`, stage + ssh + run there). Print store path. | — | — |
| `Boot` | as Build | nix-copy from build-host to target (skip when same) | ssh target: `nix-env -p sys --set <c>` + `<c>/bin/switch-to-configuration boot` |
| `Switch` | as Build | as Boot | as Boot but `switch` |
| `Test` | as Build | as Boot | ssh target: `<c>/bin/switch-to-configuration test` (no profile-set — test is non-persistent) |

Each step is one subprocess in the dispatcher's local shell. Stderr
inherits the user's terminal so nix's progress + ssh diagnostics
stream live. Stdout is piped only where a value is needed (drvPath,
store path).

## Source layout

### New file — `src/host.rs`

```rust
pub struct SshTarget(String);  // "root@<criome_domain>"

impl SshTarget {
    pub fn from_node(node: &horizon_lib::Node) -> Self { /* root@<criome_domain> */ }
    pub fn ssh_uri(&self) -> String { /* ssh-ng://root@<criome_domain> */ }
    pub fn as_ssh_arg(&self) -> &str { … }
}

pub struct RemoteStaging { target: SshTarget, remote_root: PathBuf }

impl RemoteStaging {
    pub fn try_create(target: SshTarget) -> Result<Self> {
        // ssh root@target "mktemp -d /tmp/lojix-stage.XXXXXX"
    }
    pub fn rsync(&self, local_dir: &Path, name: &str) -> Result<OverrideUri> {
        // rsync -a --delete <local_dir>/ root@target:<remote_root>/<name>/
        // returns OverrideUri::from_local_path(remote_root.join(name))
        // — the URI is interpreted on the remote, where the path now exists
    }
    pub fn cleanup(self) -> Result<()> {
        // ssh root@target "rm -rf <remote_root>"
    }
}
```

`OverrideUri` keeps one type — whether `path:<p>` is interpreted
locally or remotely is a property of which host runs `nix build`,
not the URI's shape.

### Rewrite — `src/build.rs`

Drop:
- `BuildLocation { Local, Remote { host: String } }` (`String` was
  the wrong domain type; the `Local`/`Remote` fork collapses now
  that the build host is a single optional `SshTarget`).
- `ShellWord` (the manual ssh-quoter; redundant once we don't pass
  one big shell-string through ssh).
- The `nixos-rebuild` argv branch.
- The hardcoded `ssh root@localhost` escalation.

`NixBuilder` keeps its actor envelope; the data-bearing struct
becomes:

```rust
pub struct NixBuild {
    flake: FlakeRef,
    horizon_uri: OverrideUri,
    system_uri: OverrideUri,
    action: BuildAction,
    builder: Option<SshTarget>,
}

impl NixBuild {
    pub async fn run(&self) -> Result<BuildPhaseOutcome> { … }
}

pub enum BuildPhaseOutcome {
    EvalDone { drv_path: String },
    BuildDone { store_path: StorePath, location: BuildLocation },
}

pub enum BuildLocation { Dispatcher, Builder(SshTarget) }
```

Note: `BuildLocation` is reborn — but with new meaning. It now
records *where the closure landed*, not where the user asked it to
run. `Dispatcher` ↔ `Builder(_)` is genuinely different downstream
(the copy phase needs to know).

### New file — `src/copy.rs`

`ClosureCopier` actor + `ClosureCopy` data struct:

```rust
pub struct ClosureCopy {
    store_path: StorePath,
    source: BuildLocation,   // where it lives
    target: SshTarget,       // where it needs to go
}

impl ClosureCopy {
    pub async fn run(&self) -> Result<()> {
        if self.source_matches_target() { return Ok(()); }
        // dispatcher:  nix copy --to ssh-ng://<target> <path>
        // builder→tgt: nix copy --from ssh-ng://<src> --to ssh-ng://<target> <path>
    }
}
```

### New file — `src/activate.rs`

`Activator` actor + `SystemActivation` data struct:

```rust
pub struct SystemActivation {
    target: SshTarget,
    store_path: StorePath,
    action: BuildAction,    // Boot | Switch | Test
}

impl SystemActivation {
    pub async fn run(&self) -> Result<()> {
        // ssh root@<target> "<cmd>"
        // cmd = "nix-env -p /nix/var/nix/profiles/system --set <p> && <p>/bin/switch-to-configuration <a>"
        //   for Boot/Switch
        // cmd = "<p>/bin/switch-to-configuration test"
        //   for Test
    }
}
```

### Wiring — `src/deploy.rs`

`DeployRequest` grows `builder: Option<NodeName>`. `DeployState::run`:

1. Read proposal (unchanged).
2. Project (unchanged).
3. Materialize (unchanged).
4. **Resolve target** from `horizon.node` → `SshTarget`.
5. **Resolve builder** from `horizon.ex_nodes.<builder-name>` if
   set; validate `is_builder && online` — fail fast with
   `InvalidBuilder` if not.
6. **Stage** to builder if applicable (`RemoteStaging::rsync` for
   horizon dir + system dir → two `OverrideUri`s pointing at
   remote paths).
7. **Build phase** — `NixBuild::run` → `BuildPhaseOutcome`. For
   `Eval`/`Build`, return now.
8. **Copy phase** — `ClosureCopy::run` → unit.
9. **Activate phase** — `SystemActivation::run` → unit.
10. **Cleanup** staging dir on builder.

Steps 6–10 are `await`ed sequentially in `DeployState::run`. Each
delegates to its actor via the existing `unwrap_call` helper.

### `src/error.rs`

```rust
#[error("builder {0} is not a valid builder in this horizon (is_builder=false or offline)")]
InvalidBuilder(NodeName),

#[error("builder node {0} not found in horizon ex_nodes")]
UnknownBuilder(NodeName),

#[error("rsync failed (exit {status}): {stderr}")]
RsyncFailed { status: i32, stderr: String },

#[error("ssh failed (exit {status}): {stderr}")]
SshFailed { status: i32, stderr: String },
```

`UnknownBuilder` distinguishes "you typed `--builder prometeus`"
(typo) from "the node exists but isn't a builder."

### Tests

- `tests/builder_validation.rs` — argv-shape: invalid builder
  (offline / `is_builder=false`) → `InvalidBuilder` error before
  any subprocess; unknown builder → `UnknownBuilder`.
- `tests/argv.rs` — for `Boot` action, the Activator's argv
  includes `ssh -o BatchMode=yes root@<target.criome>`. For
  `--builder X`, the rsync target is `root@<X.criome>`.
- Existing `tests/eval.rs` keeps working unchanged (no
  `--target-host`, no `--builder` ⇒ same path it tested before,
  just driven by the new pipeline).

Each test exercises the public API per
[rust/style.md §"Tests live in separate files"](../repos/tools-documentation/rust/style.md);
no `#[cfg(test)] mod tests` blocks.

## Migration — cutover

Per Li 2026-04-29: cutover, not phased. The new pipeline is genuinely
simpler than the current `ShellWord`-quoting + nixos-rebuild combo,
so coexistence scaffolding would be more code than just owning the
new path. ARCHITECTURE.md's add-before-subtract is overridden here
by direct decision; the field-deploy verification (below) is the
risk mitigation.

**Single PR.** Pre-merge gate:

1. `nix flake check` green (unit + argv-shape tests).
2. Self-deploy from ouranos succeeds: `lojix-cli deploy --node ouranos --action boot ...` lands a fresh gen.
3. Cross-node deploy from ouranos succeeds: `lojix-cli deploy --node zeus --action boot ...` lands a gen on zeus.
4. Builder deploy succeeds: `lojix-cli deploy --node zeus --action boot --builder prometheus ...` builds on prom, copies to zeus, activates on zeus.

Steps 2–4 are CriomOS-ng7's actual goldragon work; this design's
shipment *is* the closure of that issue.

## Decisions (settled)

1. **`--builder` works for all five actions** — eval, build, boot, switch, test. Same staging path; refusing it for eval/build would cost more code than enabling it.
2. **No `--target` flag** — the projected viewpoint *is* the deploy target. Allowing `--target` to escape the projection would deploy a node-N-shaped horizon onto not-N, producing identity collisions in the mesh.
3. **Offline builder fails hard, no fallback** — explicit operator decision; silently switching builders would mask infrastructure problems.
4. **`--builder == --node` is legitimate** — "build on the target itself" is a coherent ask (offload from a thin dispatcher to a beefy target). `nix build` runs on the target, no copy needed, then activate. Different from the no-`--builder` case where the dispatcher does the build.

## Out of scope

- **Streaming progress per node.** [`bd CriomOS-t50`](.) (lojix-auy).
- **Parallel `--cluster` deploys.** ARCHITECTURE.md §"Parallelism is the daemon's job."
- **`--home-only` deploy.** [`bd CriomOS-4yt`](.) — orthogonal.
- **Schema changes in horizon-rs.** None needed.

## See also

- [`bd CriomOS-6az`](.) — implementation tracker.
- [`bd CriomOS-ng7`](.) — first user; closes when this lands and prom + zeus deploy.
- [lojix-cli/ARCHITECTURE.md](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md) — migration phases (this work is intra-Phase-A).
- [horizon-rs/lib/src/node.rs](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/node.rs) — `criome_domain_name`, `is_builder`, `online`.
