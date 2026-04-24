# 2026-04-24 — horizon-rs finishing + ephemeral-flake-input architecture

Research and decisions arising from the 2026-04-24 directive: stop
having CriomOS enumerate clusters; feed it the projected horizon as
an ephemeral flake input prepared by an external Rust orchestrator
tool that runs `horizon-rs` and invokes Nix.

## 1. Verifications

### nota-serde state

Confirmed at commit [`fc005d47`](../repos/nota-serde/) — façade refactor.
The crate is now a thin re-export layer over `nota-serde-core`
(commit `be4741df`). Public surface unchanged: `from_str`, `to_string`,
`Error`, `Result`, `Serializer`, `Deserializer`. The previous impl
behaviors all hold:

- positional records (no `field=value`)
- newtype structs wrap as `(Id 42)` unless `#[serde(transparent)]`
- multi-field unnamed structs forbidden at ser/de
- bare-string emission (`is_bare_string_eligible`) for ident-shaped
  non-reserved content; deserializer accepts both bracketed and bare
  forms when the target type is a string
- char round-trip works post bare-string change (commit `66803b2`)

`horizon-rs`'s Cargo.lock has been updated. `cargo build` clean.
Goldragon's `datom.nota` projects through `horizon-cli` from all 6
viewpoints (balboa/klio/ouranos/prometheus/tiger/zeus).

### horizon-rs finished for our needs

[`horizon-j6b`](../repos/horizon-rs/) is done: `--format json|nota`
landed in [cli/src/main.rs](../repos/horizon-rs/cli/src/main.rs) with
**JSON as the default**. Both formats verified against goldragon:

- `horizon-cli --cluster goldragon --node tiger < datom.nota` → 627-line
  pretty JSON, root key `cluster.name = "goldragon"`.
- `horizon-cli --cluster goldragon --node tiger --format nota < datom.nota`
  → compact nota; round-trippable.

`horizon-rs` is now operationally complete. Remaining beads
([`horizon-3be`](../repos/horizon-rs/) iface input type,
[`horizon-4jk`](../repos/horizon-rs/) RAM-budget cap,
[`horizon-8u8`](../repos/horizon-rs/) WireguardProxy refinement,
[`horizon-12u`](../repos/horizon-rs/) closed-enum extensions) are
polish, not blockers.

## 2. New architecture

### Old model (deleted)

CriomOS exposed `crioZones.<cluster>.<node>.{os,fullOs,vm,home,deployManifest}`
by enumerating any flake input whose outputs carried a `NodeProposal`
attr. `lib.mkHorizon` was supposed to call `horizon-cli` via IFD over
that proposal. Beads
[`CriomOS-cal`](../.beads/) (P0, "implement crioZones.nix"),
[`CriomOS-lyc`](../.beads/) (P0, "wire mkHorizon via IFD"), and
[`horizon-30u`](../repos/horizon-rs/) (P1, "wire CriomOS lib.mkHorizon
via IFD") all encoded that model. **All three closed as superseded.**

### New model

CriomOS knows nothing about clusters. The `crioZones` output is gone.
Instead:

- `nixosModules.criomos` — the platform module aggregate
  (auto-derived by blueprint from
  [modules/nixos/criomos.nix](../modules/nixos/criomos.nix)).
- `lib.mkHorizon = horizonJsonPath: builtins.fromJSON (builtins.readFile horizonJsonPath);`
  — pure JSON read.

A separate **orchestrator tool** (working name `lojix`)
performs every step that used to live inside Nix:

```
goldragon/datom.nota
        │
        ▼
   horizon-rs (in-process via horizon-lib, NOT subprocess)
        │
        ▼ horizon.json
        │
        ▼ wraps in a generated flake.nix
   /tmp/<run>/flake.nix       inputs.criomos.url = "github:LiGoldragon/CriomOS";
   /tmp/<run>/horizon.json    outputs = let h = inputs.criomos.lib.mkHorizon ./horizon.json;
                                        in nixosConfigurations.target = nixosSystem { specialArgs.horizon = h; modules = [ inputs.criomos.nixosModules.criomos ]; }
        │
        ▼
   nix build / nixos-rebuild --flake /tmp/<run>#target switch
```

The wrapper flake is "ephemeral": each tool invocation creates a
fresh dir, runs nix against it, optionally tears down. Nix's eval +
build cache hits across runs because the inputs are hashed-by-content.

### Why this is better

- **CriomOS is genuinely cluster-agnostic.** The horizon could come
  from any source — goldragon today, a test fixture tomorrow,
  multiple clusters in parallel via parallel orchestrator runs.
- **No IFD.** Projection happens outside Nix; results are pre-baked.
  Faster, more debuggable, no `--allow-import-from-derivation`.
- **Type-safe projection.** The orchestrator links `horizon-lib` as
  a Rust dependency — no JSON parsing or subprocess shenanigans on
  the Rust side.
- **Naturally daemonizable.** Watch `datom.nota` for changes,
  re-project, redeploy. (Out of scope for v1, but the actor model
  makes it a small extension.)

## 3. End-to-end manual validation

Performed today as proof-of-architecture. The orchestrator tool's
work was done by hand:

```
mkdir /tmp/criomos-e2e && cd /tmp/criomos-e2e && git init -q
horizon-cli --cluster goldragon --node tiger \
  --format json < /home/li/git/goldragon/datom.nota > horizon.json
cat > flake.nix <<EOF  # see report sec 2 — wrapper flake content
git add -A
nix flake show --no-write-lock-file
nix eval .#nixosConfigurations.tiger.config.networking.hostName  # → "nixos"
nix eval .#checks.x86_64-linux.horizonReadable                   # → "goldragon"
```

`nix flake show` reports `nixosConfigurations.tiger: NixOS configuration`.
`config.system.build.toplevel.drvPath` evaluation fails with the
expected complaint about missing `fileSystems` and bootloader — the
modules under [modules/nixos/](../modules/nixos/) are still scaffold
(bead [`CriomOS-52j`](../.beads/) tracks the rewrite). The crucial
point is that the **wiring shape is sound**: horizon flows from JSON
through `lib.mkHorizon` to `nixosSystem.specialArgs.horizon` and is
visible inside the module evaluator.

## 4. Orchestrator tool — design

**Name**: `lojix`. Reusing the legacy `lojix` slot — current contents
(post the 2026 reset to "battery-included aski dialect") will move to
`lojix-archive` and a fresh `lojix` repo takes the new design. Per
2026-04-24 directive.

### Single-shot flow (CLI)

```
$ lojix deploy --cluster goldragon --node tiger --action switch
$ lojix build  --cluster goldragon --node tiger
$ lojix eval   --cluster goldragon --node tiger      # for debugging
```

Each invocation runs the actor pipeline once and exits.

### Daemon flow (later)

```
$ lojix watch --cluster goldragon
```

Watches `goldragon/datom.nota`; on change, re-projects every node and
optionally re-deploys. Out of scope for v1.

### Actors (per Mentci style: ractor for orchestration, methods on
types, typed newtypes, `thiserror` errors, edition 2024, single-object
I/O at boundaries)

```
DeployCoordinator     ← supervisor; one per (cluster, node) deploy
  ├── ProposalReader        owns: Option<ClusterProposal>; reads + caches datom.nota
  ├── HorizonProjector      stateless; horizon-lib in-process projection
  ├── FlakeArtifact         owns: TempDir; writes flake.nix + horizon.json
  └── NixBuilder            owns: ProcessHandle; spawns nix, streams stdout/stderr
```

Message shapes (sketch — exact form lives in source):

```rust
// proposal.rs
pub enum ProposalMsg {
    Read(reply: RpcReplyPort<Result<ClusterProposal, Error>>),
    // future: Watch, OnChange events to a subscriber
}

// project.rs — synchronous from orchestrator's POV; in-process
pub struct ProjectRequest {
    pub proposal: ClusterProposal,
    pub viewpoint: Viewpoint,
}
pub enum ProjectMsg {
    Project(ProjectRequest, RpcReplyPort<Result<Horizon, Error>>),
}

// artifact.rs
pub struct ArtifactRequest {
    pub horizon: Horizon,
    pub criomos_flake: FlakeRef,    // url or path
    pub target_attr:   String,      // e.g. "tiger"
}
pub enum ArtifactMsg {
    Materialize(ArtifactRequest, RpcReplyPort<Result<MaterializedFlake, Error>>),
    Cleanup(MaterializedFlake),
}

// build.rs
pub enum BuildAction { Eval, Build, Boot, Switch, Test }
pub struct BuildRequest {
    pub flake: MaterializedFlake,
    pub action: BuildAction,
}
pub enum BuildMsg {
    Run(BuildRequest, RpcReplyPort<Result<BuildOutcome, Error>>),
}

// deploy.rs — the supervisor
pub struct DeployRequest {
    pub cluster: ClusterName,        // horizon-lib newtype
    pub node:    NodeName,           // horizon-lib newtype
    pub action:  BuildAction,
    pub source:  ProposalSource,     // path to datom.nota
}
pub enum DeployMsg {
    Run(DeployRequest, RpcReplyPort<Result<BuildOutcome, Error>>),
}
```

Notes per style canon:
- `ProposalSource`, `MaterializedFlake`, `BuildOutcome`, `FlakeRef`
  are typed newtypes (no bare `String` or `PathBuf` at message
  boundaries).
- `Error` is a single `thiserror`-derived enum per crate. No
  `anyhow`/`eyre`. Inner `horizon_lib::Error` and `std::io::Error`
  flow in via `#[from]`.
- All actors expose their work as methods on their state structs;
  the `Actor` impl is a thin dispatch layer.
- Tests live under `tests/` (e.g. `tests/e2e_goldragon_tiger.rs`).

### Repo layout

```
lojix/
  Cargo.toml          edition = "2024"; deps: horizon-lib (path or git),
                      ractor, clap, thiserror, tempfile, tokio (via ractor)
  src/
    main.rs           clap entry-point; spawns DeployCoordinator
    error.rs          thiserror Error enum
    cluster.rs        ProposalSource, ClusterRef, viewpoint helpers
    proposal.rs       ProposalReader actor
    project.rs        HorizonProjector actor (wraps horizon_lib::ClusterProposal::project)
    artifact.rs       FlakeArtifact actor + wrapper-flake template
    build.rs          NixBuilder actor (process spawning, output streaming)
    deploy.rs         DeployCoordinator (supervisor)
  tests/
    e2e_eval.rs       run `lojix eval` against goldragon, assert success
    e2e_build.rs      ditto for `build`; gated behind a feature flag for CI
  AGENTS.md
  README.md
  .beads/
```

### Wrapper-flake template (the artifact actor writes this)

```nix
{
  description = "Generated horizon harness for {{cluster}}.{{node}}.";
  inputs = {
    criomos.url = "{{criomos_flake_ref}}";
  };
  outputs = inputs:
    let
      horizon = inputs.criomos.lib.mkHorizon ./horizon.json;
      nixpkgs = inputs.criomos.inputs.nixpkgs;
    in {
      nixosConfigurations."{{node}}" = nixpkgs.lib.nixosSystem {
        system = "{{system_tuple}}";
        specialArgs = { inherit horizon; };
        modules = [ inputs.criomos.nixosModules.criomos ];
      };
    };
}
```

Field substitutions:
- `{{cluster}}`, `{{node}}` from `DeployRequest`
- `{{criomos_flake_ref}}` defaults to `github:LiGoldragon/CriomOS` but
  can be overridden (e.g. `path:/home/li/git/CriomOS` for dev)
- `{{system_tuple}}` derived from `horizon.node.system`
  (`X86_64Linux` → `x86_64-linux`, `Aarch64Linux` → `aarch64-linux`)

### Lifecycle

1. `DeployCoordinator` spawns the four child actors with restart
   strategy `OneForOne`.
2. Sends `ProposalReader::Read`. Got `ClusterProposal`.
3. Sends `HorizonProjector::Project { proposal, viewpoint }`. Got
   `Horizon`.
4. Sends `FlakeArtifact::Materialize`. Got `MaterializedFlake { dir,
   horizon_json_path, flake_nix_path }`.
5. Sends `NixBuilder::Run { flake, action }`. Streams nix output to
   stderr; collects exit status.
6. Sends `FlakeArtifact::Cleanup(flake)`.
7. Replies to caller with `BuildOutcome`.

If a child crashes mid-pipeline, `OneForOne` restarts it and the
coordinator re-issues the message that failed (idempotent for all
actors except `NixBuilder` which may have deployed partial state —
`Switch` failure leaves the system in a known-bad state and surfaces
to the operator).

## 5. Bead changes

**Closed today (superseded by new architecture):**
- [`CriomOS-cal`](../.beads/) (P0) — crioZones.nix design dropped
- [`CriomOS-lyc`](../.beads/) (P0) — IFD model dropped
- [`horizon-30u`](../repos/horizon-rs/) (P1) — IFD wiring dropped

**Closed today (work done):**
- [`horizon-j6b`](../repos/horizon-rs/) (P1) — `--format json` shipped
- [`gold-alz`](../repos/goldragon/) (P2) — prometheus added
- [`gold-jsm`](../repos/goldragon/) (P3) — xerxes removed (irrelevant)

**To file (post user-confirmation):**
- *In a new repo (working name `lojix`):*
  - bootstrap repo (Cargo.toml, AGENTS.md, beads, src skeleton) — P0
  - implement each actor — P0 each (5 issues)
  - e2e test against goldragon — P0
  - daemon `watch` mode — P3
- *In CriomOS:*
  - wire `networking.hostName` from horizon in
    [modules/nixos/criomos.nix](../modules/nixos/criomos.nix) — P1
  - rewrite of remaining 33 modules to consume the new horizon shape
    and drop `world`/`pkdjz`/`proposedCrioSphere` (already tracked as
    [`CriomOS-52j`](../.beads/) — keep open) — P1

## 6. Open questions

1. **Wrapper flake reference.** Default to
   `github:LiGoldragon/CriomOS` or to `path:` for dev? Likely both:
   default to github, allow `--criomos-flake path:/...` override for
   local iteration. The Mentci convention favors flake inputs over
   path refs (cache correctness), so for production this should pin
   a commit hash.

3. **Stable artifact dir vs ephemeral.** True ephemeral
   (TempDir, gone after run) is simplest but means you can't
   re-evaluate / debug after the fact. Alternative: write to
   `~/.cache/lojix/<cluster>/<node>/` and atomically replace
   on each run. The latter plays nicer with `nixos-rebuild` rollback
   and gives an inspectable artifact. Suggest the latter.

4. **System-tuple derivation.** The horizon JSON carries
   `node.system = "X86_64Linux"` (Rust enum spelling). Either the
   tool or the wrapper flake template needs to map that to
   `x86_64-linux`. Cleaner in Rust (enum `match` is exhaustive); doing
   it in Nix would require a 2-entry attrset lookup. Suggest the tool.

5. **horizon-rs as path dep vs git dep.** During co-development, a
   path dep speeds iteration. For releases, git dep with a pinned
   commit hash. The orchestrator's `Cargo.toml` should default to git;
   developers can override locally with `[patch.crates-io]` or path
   in a workspace.

## 7. What an agent picking up tomorrow should do

If the design above is accepted: scaffold the orchestrator repo (one
new bead per actor file), write the e2e test against
goldragon/tiger, and replace the manual proof in §3 with a
`cargo test --test e2e_eval` invocation.

If the design needs revision: comment on the open questions in §6
and we redesign before any code lands.
