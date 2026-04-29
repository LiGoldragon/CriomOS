# lojix-cli cross-node deploy + builder selection — design

The current `lojix-cli` privileged tail is hardcoded to
`ssh -o BatchMode=yes root@localhost`. This pins the deploy *target*
to the host running `lojix-cli`, and offers no surface for picking
a *builder*. Two capabilities are missing: deploying a node from a
different node, and choosing where the closure builds.

This report names the noun, lays the surface against the existing
code, and surfaces decisions before any implementation.

## Two axes, both already in the horizon

The `Horizon` projected by `horizon-rs` already carries everything
needed; no schema change.

| axis | concept | source of truth |
|---|---|---|
| **target** | which node's `/nix/var/nix/profiles/system` + bootloader is mutated | `horizon.node.criomeDomainName` (the projection's viewpoint) |
| **builder** | which node runs `nix build` for the closure | `horizon.exNodes.<n>.criomeDomainName` for the chosen builder, gated by `horizon.exNodes.<n>.isBuilder && online` |

`--node` already names the projection viewpoint — that *is* the
target by construction (you project from the node you're deploying).
The remaining surface is the **builder**.

Both addresses come from `criome_domain_name`
([horizon-rs/lib/src/node.rs:45](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/node.rs#L45)),
which is already the canonical address everywhere else in the
ecosystem (it's what `BuilderConfig::host_name` uses, what /etc/hosts
populates, what `nix.buildMachines.<n>.hostName` resolves through).

This satisfies the [Node-Horizon Toggle Policy](../docs/GUIDELINES.md#node-horizon-toggle-policy):
no host-name literals leak into lojix-cli — the wire is `NodeName`,
the resolution is `horizon.<n>.criomeDomainName`.

## CLI surface

```
lojix-cli deploy --cluster goldragon --node zeus \
  --source ~/git/goldragon/datom.nota \
  --action boot \
  --criomos github:LiGoldragon/CriomOS/<rev> \
  [--builder prometheus]
```

| flag | meaning | default |
|---|---|---|
| `--node <name>` | projection viewpoint = deploy target | required |
| `--builder <name>` | sibling node that runs `nix build`; must be `is_builder && online` in the projected horizon | absent = build locally |

`--builder` accepts a `NodeName`, not an ssh string. Resolution to
`<n>.<cluster>.criome` is internal. This keeps the boundary in
domain values, per [rust/style.md §"Domain values are types, not primitives"](../repos/tools-documentation/rust/style.md).

`--target-host` is **not** a separate flag. The "node being
deployed" and "host where the privileged tail lands" are the same
concept; fragmenting them into two flags would be the
[GUIDELINES.md "names are commitments"](../docs/GUIDELINES.md#naming-is-a-semantic-layer)
violation.

## Why nixos-rebuild's flags, not lojix-cli's own ssh

`nixos-rebuild` already implements `--target-host` and
`--build-host` correctly: it evaluates the flake locally (so
`--override-input horizon path:~/.cache/lojix/...` resolves where
the user-side cache lives), builds the closure (locally or via the
build-host), copies it via `nix copy --to ssh-ng://target`, then
activates remotely with `switch-to-configuration <action>`.

This is what
[lojix-cli/ARCHITECTURE.md §"Remote builds — two meanings"](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md#remote-builds--two-meanings)
recommends:

> `nixos-rebuild --target-host X --build-host Y` already covers
> many of these patterns natively — invoke it via
> `BuildAction::Switch` without lojix-cli needing its own SSH
> stack.

So this work *deletes* the `ShellWord` quoter and the manual ssh
wrap in `NixInvocation::run` — they become dead code once
`--target-host` is the universal path. Per
[push-not-pull](../repos/tools-documentation/programming/push-not-pull.md),
the right structure is to let the producer (nixos-rebuild) push
the closure through its own subscription primitive, not to
re-implement closure-copy + activation in lojix-cli.

## Source shape

### New domain type — `SshTarget`

In `src/host.rs` (new file, one concern per file per
[rust/style.md §"Module layout"](../repos/tools-documentation/rust/style.md)):

```rust
/// `root@<node>.<cluster>.criome` — the address nixos-rebuild
/// uses for `--target-host` / `--build-host`.
pub struct SshTarget(String);

impl SshTarget {
    pub fn from_horizon_node(node: &horizon_lib::Node) -> Self {
        Self(format!("root@{}", node.criome_domain_name.as_str()))
    }
    pub fn as_str(&self) -> &str { &self.0 }
}
```

The wrapped field is private; construction goes through the
`from_*` direction-encoded constructor. Per
[GUIDELINES.md §"Direction Encodes Action"](../docs/GUIDELINES.md#direction-encodes-action).

### `BuildLocation` retypes — drop `Local`/`Remote` fork

`build.rs` today carries:

```rust
pub enum BuildLocation { Local, Remote { host: String } }
```

`String` is wrong (domain values are types) and `Local` is now
redundant — every action with a privileged tail goes through
`--target-host`, so the "local" case is just "target == this host."

New shape:

```rust
pub struct NixInvocation {
    flake: FlakeRef,
    horizon_uri: OverrideUri,
    system_uri: OverrideUri,
    action: BuildAction,
    target: SshTarget,            // always present
    builder: Option<SshTarget>,   // None = build on target
}
```

`NixInvocation::run` synthesises the argv:

- For `Eval` / `Build`: `nix eval` / `nix build` runs locally.
  `--target-host` does not apply (no activation). When `builder`
  is `Some`, the `Build` action passes `--builders ssh-ng://<host>`
  + `--max-jobs 0` so the daemon dispatches to the chosen builder.
  *(Decision 1 below — alternative: error out if `--builder` is
  set with `Build` / `Eval`.)*
- For `Boot` / `Switch` / `Test`: invoke
  `nixos-rebuild <action> --flake <ref>#target --override-input horizon ... --override-input system ... --target-host <target> [--build-host <builder>]`.
  No manual ssh-wrap. nixos-rebuild handles closure-copy +
  privileged activation.

### Wiring through the actors

The `DeployRequest` grows one field:

```rust
pub struct DeployRequest {
    pub cluster: ClusterName,
    pub node: NodeName,
    pub builder: Option<NodeName>,   // NEW
    pub action: BuildAction,
    pub source: ProposalSource,
    pub criomos: FlakeRef,
}
```

`DeployState::run` resolves `target` from the projected horizon's
viewpoint node (`horizon.node`) and `builder` from `horizon.ex_nodes`,
validating `is_builder && online`. Both become `SshTarget`s passed
into `BuildMsg::Run`.

`BuildMsg::Run` grows two fields (`target: SshTarget`,
`builder: Option<SshTarget>`); the `NixBuilder` actor passes them
into `NixInvocation::new` (or a new `with_builder` constructor —
see [rust/style.md §"Constructors"](../repos/tools-documentation/rust/style.md)
for `with_<thing>` semantics).

### Errors

Two new variants in `src/error.rs`:

```rust
#[error("builder {0} is not a valid builder in this horizon (is_builder=false or offline)")]
InvalidBuilder(NodeName),

#[error("builder {0} is the same as the deploy target; pick a different node or omit --builder")]
SelfBuild(NodeName),
```

Both validations happen in `DeployState::run`, after the projection
returns and the horizon is in hand.

## What this changes operationally

### Today

```bash
# Run on the target node only — localhost is hardcoded
ouranos$ lojix-cli deploy --node ouranos --action boot ...
```

### After this change

```bash
# Self-deploy — same shape, but ssh now goes to ouranos.goldragon.criome
ouranos$ lojix-cli deploy --node ouranos --action boot ...

# Deploy zeus from ouranos — was impossible
ouranos$ lojix-cli deploy --node zeus --action boot ...

# Deploy zeus from ouranos, using prometheus as builder (heavy node)
ouranos$ lojix-cli deploy --node zeus --action boot --builder prometheus ...
```

The "self" case still works because `ssh root@ouranos.goldragon.criome`
from ouranos resolves through `/etc/hosts` and ouranos's own sshd
accepts the dispatcher's host key (this is already the
key-distribution shape `horizon.adminSshPubKeys` /
`horizon.dispatchersSshPubKeys` produce).

### Behavioural change worth flagging

The user-side cache path `~/.cache/lojix/horizon/<C>/<N>/` is read
**locally** (where lojix-cli runs); nixos-rebuild's
`--override-input horizon path:...` is resolved at eval time,
which is local. The closure is then copied to the target. So:

- The cache lives on the dispatcher (good — preserves user-side
  cache reuse across deploys, per
  [`bd memories deploy`](.) "Deploy via lojix-cli (system OR home);
  never sudo; ssh root@localhost only for the system-deploy
  commands lojix runs").
- The target node never sees the cache directory — closures arrive
  via `nix copy`. This is correct.

## Decisions to surface to Li

### Decision 1 — `--builder` with `Build` / `Eval`

Three options:

1. **Reject** — emit a clear error: "`--builder` is only meaningful
   for `Boot` / `Switch` / `Test`." Simplest. V1 candidate.
2. **Honour for `Build`, reject for `Eval`** — wire
   `--builders ssh-ng://...` for `Build` (the closure pre-warm use
   case). `Eval` can't use a remote builder by definition.
3. **Defer** — leave `--builder` accepted everywhere but no-op for
   `Eval`, document the gap.

Recommendation: **(1) for V1**. The pre-warm case can be served by
`lojix-cli build --node <heavy>` run *on* the build host; cross-node
build dispatch is an optional convenience, not load-bearing.

### Decision 2 — explicit `--target` flag, ever?

The design above conflates `--node` and target. The case for an
explicit `--target` flag:

- Some other node's *horizon projection* could be deployed to a
  different host (e.g., recovery: project zeus's horizon, deploy it
  to a spare ThinkPad acting as zeus). Today: impossible without
  swapping hardware identities.

The case against:

- The projected horizon bakes the target's identity (`name`,
  `criomeDomainName`, `nodeIp`, `yggAddress`, ssh host pubkey via
  `nix.buildMachines`/`programs.ssh.knownHosts`). Deploying a
  zeus-projection onto not-zeus produces a system that announces
  itself as zeus and trusts zeus's keys — recipe for a split-brain
  in the mesh.
- The "noun is the cluster member" framing is what makes the
  network-neutrality discipline work. Letting `--target` escape
  the projection breaks it.

Recommendation: **no `--target` flag**. If recovery-style
re-deployment is needed, that's a `datom.nota` change (rename or
reassign the node), not a CLI flag.

### Decision 3 — validate `--builder` is online

The horizon already carries
`exNodes.<n>.online` ([proposal.rs:78](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/proposal.rs#L78))
and `isBuilder` already gates on `online`. So
`builder.is_builder` already implies online; explicit re-check is
defensive but cheap.

Recommendation: **do the explicit check**, with the dedicated
`InvalidBuilder` error variant — better error message than letting
`nixos-rebuild --build-host` fail with a TCP timeout.

### Decision 4 — `--build-host` for the same-as-target case

If the user passes `--builder zeus` and `--node zeus`, that's
"build the zeus closure on zeus, then deploy on zeus" — equivalent
to *not* passing `--builder` (nixos-rebuild builds locally on the
target by default when `--target-host == --build-host`).

Two readings:

1. **Reject** — `SelfBuild` error variant above. Surfaces the
   redundancy.
2. **Silently normalise** to `builder = None`. Cleaner UX.

Recommendation: **reject**. The redundancy is an operator mistake
worth flagging; silent normalisation hides it. The error message
points at the right fix ("omit --builder").

## Out of scope

- **Streaming progress per node.** Tracked in
  [`bd CriomOS-t50`](.) (lojix-auy). This work doesn't touch
  output streaming — `stderr=inherit` keeps live nix progress as
  before; with `--target-host`, nixos-rebuild's per-step messages
  also stream through that handle.
- **Parallel multi-node `--cluster` deploy.** Tracked in
  ARCHITECTURE.md §"Parallelism is the daemon's job" — wire
  client-side parallelism only when the desired UX is one-shot
  `lojix-cli build --cluster goldragon`.
- **`--home-only` deploy.** Tracked in
  [`bd CriomOS-4yt`](.); orthogonal — concerns *what* gets
  rebuilt, not *where*.
- **Schema changes in horizon-rs.** None needed; everything this
  design uses (`criome_domain_name`, `is_builder`, `online`,
  `ex_nodes`) is already projected.

## Migration plan — add-before-subtract

Per [lojix-cli/ARCHITECTURE.md §"Add-before-subtract"](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md#add-before-subtract):

1. **Add** `--builder` flag, `SshTarget` type, validation, and the
   nixos-rebuild `--target-host`/`--build-host` invocation path —
   gated behind a feature flag or new code path. Old
   `ssh root@localhost` wrap stays.
2. **Verify** with a real deploy: zeus from ouranos with
   `--builder prometheus`. Check (a) closure builds on prometheus
   (`nix copy` activity in `journalctl -u nix-daemon` on prom),
   (b) closure copies to zeus, (c) zeus boot loader gen lands.
3. **Switch** the default for self-deploys onto the new path —
   `nixos-rebuild --target-host root@<self>.criome` replaces the
   `ssh root@localhost <command>` wrap.
4. **Run in parallel** — the new path is now the only path; both
   "self" and "other" deploys go through nixos-rebuild's
   `--target-host`. Verify a second clean deploy.
5. **Remove** `ShellWord`, the manual ssh-wrap branch in
   `NixInvocation::run`, and the `BuildLocation` enum.

Step 5 deletes ~60 lines of `build.rs` (the ssh-quoting + branch).
That deletion is the win — fewer special cases, one path, the
[beauty.md "special cases collapsing into the normal case"](../repos/tools-documentation/programming/beauty.md#what-ugliness-signals)
shape.

## Tests

`tests/eval.rs` already exercises the `eval` happy path. New tests:

- `tests/builder.rs` — invalid builder (not `is_builder` in
  horizon) → `InvalidBuilder` error; same-node builder →
  `SelfBuild` error; valid builder → argv contains
  `--build-host root@<builder>.<cluster>.criome`.
- `tests/target.rs` — argv for `Boot` action contains
  `--target-host root@<node>.<cluster>.criome` regardless of where
  lojix-cli runs.

Both can be argv-shape tests; no live deploy needed in CI. The
field deploy in step 2 of the migration is the integration test.

## See also

- [lojix-cli/ARCHITECTURE.md](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md) —
  add-before-subtract, the two meanings of "remote build"
- [tools-documentation/lojix-cli/basic-usage.md](../repos/tools-documentation/lojix-cli/basic-usage.md) —
  current usage; rewrite needed once `--builder` lands
- [horizon-rs/lib/src/node.rs](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/node.rs) —
  `criome_domain_name`, `is_builder`, `online`, `BuilderConfig`
- [bd CriomOS-ng7](.) — prom + zeus pending deploy; first user of
  `--builder` once landed
