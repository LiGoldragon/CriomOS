# 2026-04-24 — horizon-rs finishing + horizon-as-flake-input architecture

Research and decisions arising from the 2026-04-24 directives:

1. Stop having CriomOS enumerate clusters.
2. Make `horizon` a **flake input to CriomOS itself**, not the other
   way around. The `lojix` orchestrator tool produces a horizon flake
   (or FOD) and overrides this input. Same horizon content → same
   narHash → same store path → nix eval/build cache hits across runs.
3. horizon-rs is therefore **not** a CriomOS input; it's lojix's
   dependency.

## 1. Verifications

### nota-serde state

Confirmed at commit [`fc005d47`](../repos/nota-serde/) — façade
refactor over [nota-serde-core](../repos/nota-serde-core/) at commit
`be4741df`. Public surface unchanged: `from_str`, `to_string`,
`Error`, `Result`, `Serializer`, `Deserializer`. The previous impl
behaviors all hold (positional records, transparent newtype handling,
multi-field unnamed structs forbidden, bare-string emission).
horizon-rs picks up both via `cargo update`.

### horizon-rs finished for our needs

`horizon-cli` now has `--format json|nota`, JSON default. All 6
goldragon viewpoints (balboa/klio/ouranos/prometheus/tiger/zeus)
project cleanly. horizon-rs is operationally complete. Remaining
beads are polish.

## 2. Architecture (revised)

### Direction of the horizon dependency

| | Old (rejected) | New |
|---|---|---|
| flake input direction | wrapper flake imports CriomOS | CriomOS imports `horizon` |
| who supplies horizon | wrapper flake wires it as `specialArg` | lojix overrides CriomOS's `horizon` input |
| nix cache property | per-wrapper-flake (no sharing) | per-horizon-content (shared across runs) |
| horizon-rs as CriomOS input? | yes | **no** |

### CriomOS shape

```
CriomOS/
  flake.nix               inputs.horizon.url = "path:./stubs/no-horizon";   # default stub throws
                          outputs.nixosConfigurations.target = nixosSystem
                            { specialArgs.horizon = inputs.horizon.horizon; … };
                          outputs.horizonProbe = inputs.horizon.horizon;     # debug surface
  stubs/no-horizon/flake.nix  outputs.horizon = throw "…";                   # friendly error
  lib/default.nix         (no mkHorizon — modules read horizon from specialArgs;
                          ad-hoc readers use builtins.fromJSON inline.)
  modules/nixos/criomos.nix  the platform module aggregate (specialArg `horizon` available)
```

### lojix invocation

```
nixos-rebuild switch \
  --flake github:LiGoldragon/CriomOS#target \
  --override-input horizon path:<horizon-dir>
```

`<horizon-dir>` contains exactly two files:

```
horizon-dir/
  flake.nix      { outputs = _: { horizon = builtins.fromJSON (builtins.readFile ./horizon.json); }; }
  horizon.json   <horizon-cli --format json output>
```

No `.git`, no extras — those would alter the directory's narHash and
break the cache property.

## 3. Cache property — measured

Setup: three dirs at `/tmp/horizon-{tiger,balboa,tiger-copy}` with
the structure above. tiger and tiger-copy hold byte-identical
horizon JSON (different paths). balboa holds a different node's
projection.

Test command:
```
nix eval --raw .#horizonProbe.cluster.name --override-input horizon path:<dir>
```

| Run | Path | narHash (truncated) | Output | Notes |
|---|---|---|---|---|
| 1 | tiger | `EP9cznNJyQu7j+Lq35U6mC7Kg2k…` | `goldragon` | first eval |
| 2 | tiger | `EP9cznNJyQu7j+Lq35U6mC7Kg2k…` | `goldragon` | 10× faster (cache hit) |
| 3 | tiger-copy | `EP9cznNJyQu7j+Lq35U6mC7Kg2k…` | `goldragon` | **identical narHash** to tiger |
| 4 | balboa | `mrC9fYBb+UWEee6QPn5P1nyYlfi…` | `balboa` | distinct narHash |

The architecture works. Same horizon content → same store path →
nix's eval cache hits, regardless of what dir lojix wrote it to.

A **gotcha** found during testing: a `.git` directory inside the
override path makes nix include it in the narHash, breaking the
cache property even when content is identical. Lojix must write the
override dir as a plain dir, never `git init` it.

## 4. Portable horizon — content-addressed archive

`path:` URIs only work on the machine where lojix ran. For
distributed builds (one machine generates the horizon, another
consumes it), the override needs to be fetchable.

### Mechanism

Nix supports `tarball+<url>?narHash=sha256-...` as a flake input
URI. The `narHash` query parameter is the SRI form of the unpacked
narHash (the same hash that `path:` inputs compute intrinsically).
Nix fetches the tarball, unpacks, validates against the narHash, and
either rejects (mismatch) or uses (match). Same hash → same store
path → eval/build cache hits across all machines that share a binary
cache or have already evaluated that horizon.

### Lojix flow

1. Project horizon, write `flake.nix` + `horizon.json` to a temp dir
   (no `.git`).
2. Compute narHash:
   `nix hash path --type sha256 --sri <dir>` → `sha256-EP9cznN…`.
3. Convert to nix32 and take the **first 6 chars** as a short
   collision-resistant prefix:
   `nix hash convert --to nix32 --hash-algo sha256 sha256-EP9cznN…`
   → `13k2sfnamn2qgm36hr0bd61wlblq7aaxzsp2iyxhpja9fg75rzqh` →
   short = `13k2sf`. (6 nix32 chars ≈ 30 bits ≈ 1B combos —
   collision-safe for per-(cluster,node)-per-deploy horizons over
   any realistic lifetime; the full narHash stays in the URI query
   for actual verification, so a collision in the prefix would only
   cause an accidental overwrite of the upload, not a security
   problem.)
4. Tar+gzip the dir as `<cluster>-<node>-<short>.tar.gz` — e.g.
   `goldragon-tiger-13k2sf.tar.gz`. The tar bytes themselves don't
   need to be deterministic — only the unpacked contents do, since
   nix re-computes the narHash on extraction.
5. Upload to the publish target (TBD — see open questions).
6. Emit the override URI:
   `tarball+<url>/horizon-<nix32>.tar.gz?narHash=sha256-EP9cznN…`.

### Consumer (any machine)

```
nixos-rebuild switch \
  --flake github:LiGoldragon/CriomOS#target \
  --override-input horizon \
    "tarball+https://horizons.example/horizon-<nix32>.tar.gz?narHash=sha256-EP9cznN..."
```

### Measured (this session)

```
nix hash path --type sha256 --sri /tmp/horizon-tiger
  → sha256-EP9cznNJyQu7j+Lq35U6mC7Kg2kLZGhGfVjYqqzTYo4=

tar -C /tmp/horizon-tiger -czf /tmp/horizon-<nix32>.tar.gz .

nix eval --raw .#horizonProbe.cluster.name \
  --override-input horizon "tarball+file:///tmp/horizon-<nix32>.tar.gz?narHash=sha256-EP9cznN..."
  → goldragon                                    # success

nix eval --raw .#horizonProbe.cluster.name \
  --override-input horizon "tarball+file:///...?narHash=sha256-AAAA..."
  → error: NAR hash mismatch in input ...        # rejected
```

The narHash from `nix hash path` on the source dir is the same
narHash nix computes on the unpacked tarball — verified by both
the success and the mismatch error above.

### Where to upload

The mechanism is upload-target-agnostic. Candidates:

| Target | Pros | Cons |
|---|---|---|
| GitHub releases on a `goldragon-horizons` repo | free, durable, immutable, browsable | release-create rate limits; needs a token |
| S3 / R2 / B2 bucket | cheap, scalable, content-addressed paths trivial | needs cloud account + creds |
| nix binary cache (cachix, attic, self-hosted) | re-uses nix-native distribution | overkill for ~3KB horizons; binary caches optimise build outputs not source |
| HTTP server on a node in the kriom (e.g. `https://prometheus.goldragon.criome/horizons/`) | self-hosted; same trust domain | requires the kriom to be up; chicken-and-egg for first deploy |

The mechanism is identical across these — only the URL prefix
changes. Decision deferred (see open questions).

## 5. About FOD as an alternative

Content-addressed path inputs (the approach above) work via nix's
intrinsic narHashing. An explicit FOD wrapper is **not required**
for v1, but it's a viable upgrade if we later want stricter
guarantees:

```nix
# what lojix could emit instead of the simple wrapper
{
  outputs = _: {
    horizon = derivation {
      name = "horizon-${precomputedSha256}.json";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "cp ${./horizon.json} $out" ];
      outputHash     = precomputedSha256;
      outputHashAlgo = "sha256";
      outputHashMode = "flat";
    };
  };
}
```

CriomOS modules would then consume `inputs.horizon.horizon` as a
derivation outPath (not a value) and parse via
`builtins.fromJSON (builtins.readFile inputs.horizon.horizon)`.
Stricter than narHash-of-flake-dir; pre-computes the store path
without nix needing to scan the dir.

For v1: stick with the simple wrapper (no FOD). Revisit if the
narHash-of-dir approach surfaces edge cases.

## 6. lojix orchestrator — design

**Name**: `lojix`. The legacy `lojix` repo (current contents:
3-file scaffold post the 2026 reset to "battery-included aski
dialect") moves to `lojix-archive`; a fresh `lojix` repo takes the
new design. Per 2026-04-24 directive.

### CLI

```
$ lojix deploy --cluster goldragon --node tiger --action switch
$ lojix build  --cluster goldragon --node tiger
$ lojix eval   --cluster goldragon --node tiger     # debug
$ lojix watch  --cluster goldragon                  # daemon (later)
```

### Single-shot pipeline

```
goldragon/datom.nota
        │
        ▼  ProposalReader actor (in-process, file watch optional)
   ClusterProposal
        │
        ▼  HorizonProjector actor (horizon-lib in-process; NOT subprocess)
   Horizon (typed Rust)
        │
        ▼  HorizonArtifact actor (writes dir, computes narHash, tars,
        │                         optionally uploads)
   <override-dir>/                  + horizon-<nix32>.tar.gz @ <upload-url>
     ├─ flake.nix                     (with narHash known)
     └─ horizon.json
        │
        ▼  NixBuilder actor (spawns nix; streams stdout/stderr)
   nixos-rebuild --flake github:LiGoldragon/CriomOS#target
                 --override-input horizon "<path or tarball+url?narHash=...>"
                 <action>
        │
        ▼  BuildOutcome (success | failure with diagnostics)
        │
        ▼  HorizonArtifact actor: optional Cleanup (local), retain remote
```

### Actors (per Mentci style: ractor for orchestration, methods on
types, typed newtypes, `thiserror` errors, edition 2024, single-object
I/O at boundaries)

```
DeployCoordinator     ← supervisor; OneForOne; one per (cluster, node) deploy
  ├── ProposalReader        owns: Option<ClusterProposal>; reads + caches datom.nota
  ├── HorizonProjector      stateless; horizon-lib in-process
  ├── HorizonArtifact       owns: PathBuf (override-dir lifetime)
  └── NixBuilder            owns: ProcessHandle; spawn nix; stream output
```

Message shapes (sketch):

```rust
// proposal.rs
pub enum ProposalMsg {
    Read(RpcReplyPort<Result<ClusterProposal, Error>>),
    // future: Watch(path: ProposalSource), OnChange events
}

// project.rs
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
    pub publish: Option<PublishTarget>,   // None = local path:; Some = upload + tarball URI
}
pub struct HorizonArtifact {
    pub local_dir:    PathBuf,            // contains flake.nix + horizon.json
    pub nar_hash_sri: NarHashSri,         // sha256-...= form
    pub override_uri: OverrideUri,        // path:<dir>  or  tarball+<url>?narHash=...
}
pub enum ArtifactMsg {
    Materialize(ArtifactRequest, RpcReplyPort<Result<HorizonArtifact, Error>>),
    Cleanup(HorizonArtifact),
}

// build.rs
pub enum BuildAction { Eval, Build, Boot, Switch, Test }
pub struct BuildRequest {
    pub criomos_flake: FlakeRef,        // default: github:LiGoldragon/CriomOS
    pub artifact:      HorizonArtifact, // override_uri picks path: or tarball:
    pub action:        BuildAction,
}
pub enum BuildMsg {
    Run(BuildRequest, RpcReplyPort<Result<BuildOutcome, Error>>),
}

// deploy.rs (supervisor)
pub struct DeployRequest {
    pub cluster: ClusterName,           // horizon-lib newtype
    pub node:    NodeName,              // horizon-lib newtype
    pub action:  BuildAction,
    pub source:  ProposalSource,        // newtype(PathBuf)
    pub criomos: FlakeRef,              // default: github:LiGoldragon/CriomOS
}
pub enum DeployMsg {
    Run(DeployRequest, RpcReplyPort<Result<BuildOutcome, Error>>),
}
```

Style notes:
- `ProposalSource`, `HorizonArtifact`, `BuildOutcome`, `FlakeRef`
  are typed newtypes — no bare `String`/`PathBuf` at boundaries.
- `Error` is one `thiserror`-derived enum per crate; inner errors
  wrap via `#[from]`.
- All actor work lives as methods on the state struct; `Actor`
  impls are thin dispatch.
- Tests under `tests/` (e.g. `tests/e2e_goldragon_tiger.rs`).

### Repo layout

```
lojix/
  Cargo.toml          edition = "2024";
                      deps: horizon-lib (git or path), ractor, clap,
                            thiserror, tempfile (or directories), tokio (via ractor),
                            serde_json
  src/
    main.rs           clap entry-point; spawns DeployCoordinator
    error.rs          thiserror Error enum
    cluster.rs        ProposalSource, FlakeRef, viewpoint helpers
    proposal.rs       ProposalReader actor
    project.rs        HorizonProjector actor (horizon-lib::ClusterProposal::project)
    artifact.rs       HorizonArtifact actor + the wrapper-flake template constant
    build.rs          NixBuilder actor (nix subprocess; stdio streaming)
    deploy.rs         DeployCoordinator (supervisor)
  tests/
    e2e_eval.rs       lojix eval --cluster goldragon --node tiger; assert success
    e2e_build.rs      lojix build; gated behind a feature flag
  AGENTS.md
  README.md
  .beads/
```

### Wrapper-flake template (constant; lojix writes it verbatim)

```nix
{
  description = "lojix-generated horizon flake (override-input target).";
  outputs = _: {
    horizon = builtins.fromJSON (builtins.readFile ./horizon.json);
  };
}
```

The horizon.json file alongside it is the only varying content.

### Lifecycle

1. `DeployCoordinator` spawns the four child actors; OneForOne strategy.
2. `ProposalReader::Read` → `ClusterProposal`.
3. `HorizonProjector::Project { proposal, viewpoint }` → `Horizon`.
4. `HorizonArtifact::Materialize { horizon }` → `HorizonArtifact { dir }`.
5. `NixBuilder::Run { criomos_flake, artifact, action }`. Streams nix
   output to stderr; collects exit status into `BuildOutcome`.
6. `HorizonArtifact::Cleanup` (or skip if persistent dir was used).
7. Reply to caller with `BuildOutcome`.

If a child crashes mid-pipeline, OneForOne restarts it; the
coordinator re-issues the message that failed (idempotent for all
except `NixBuilder` `Switch`, which may have left partial state and
must surface to the operator).

## 7. Bead changes

**Closed today (superseded by new architecture):**
- [`CriomOS-cal`](../.beads/) (P0) — crioZones.nix design dropped.
- [`CriomOS-lyc`](../.beads/) (P0) — IFD model dropped.
- [`horizon-30u`](../repos/horizon-rs/) (P1) — IFD wiring dropped.

**Closed today (work done):**
- [`horizon-j6b`](../repos/horizon-rs/) (P1) — `--format json` shipped.
- [`gold-alz`](../repos/goldragon/) (P2) — prometheus added.
- [`gold-jsm`](../repos/goldragon/) (P3) — xerxes removed.

**To file (after user-confirmation):**
- *In a new repo (`lojix`, post archive of legacy `lojix`):*
  - bootstrap repo (Cargo.toml, AGENTS.md, beads, src skeleton) — P0
  - implement each actor (5 issues) — P0
  - e2e test against goldragon — P0
  - daemon `watch` mode — P3
- *In CriomOS:*
  - rewrite of remaining 33 modules to consume the flat horizon shape
    and drop `world`/`pkdjz`/`proposedCrioSphere` (already tracked as
    [`CriomOS-52j`](../.beads/) — keep open) — P1
  - wire `networking.hostName` and `system.stateVersion` from horizon
    in [modules/nixos/criomos.nix](../modules/nixos/criomos.nix) —
    smallest module port to make `nix eval ...drvPath` actually
    succeed end-to-end — P1

## 8. Open questions

1. **Where to publish horizon archives.** See §4 — GitHub releases
   on a `goldragon-horizons` repo, S3/R2/B2 bucket, kriom-hosted
   HTTP, or a nix binary cache. Top recommendation: GitHub releases
   on a dedicated `goldragon-horizons` repo (immutable, free,
   browsable, and the URL pattern is stable). Confirm before lojix
   wires the publish action.

2. **Local-only mode.** For dev iteration on a single machine, lojix
   should support a `--no-publish` flag that emits a `path:` URI
   instead of `tarball+`. Same cache property locally; skips upload.

3. **Override path stability (when local).** True ephemeral
   (TempDir, gone after run) is simplest but means you can't
   re-evaluate / debug after the fact. Stable alternative: write to
   `~/.cache/lojix/<cluster>/<node>/<6char>/` (path encodes the
   horizon's short hash). Cache-correct either way; the stable form
   gives an inspectable artifact and survives a kill -9. **Suggest
   stable.**

4. **System-tuple derivation.** Currently in CriomOS `flake.nix`
   inline (`{ X86_64Linux = "x86_64-linux"; … }.${horizon.node.system}`).
   Could move to lojix and have it set the `system` argument
   explicitly via a wrapper, but then CriomOS needs *some* signal of
   target system anyway. Inline-in-CriomOS is fine.

5. **horizon-lib as path dep vs git dep in lojix's Cargo.toml.**
   During co-development, path dep speeds iteration. For releases,
   git dep with pinned commit. Suggest git dep default; developers
   override locally with `[patch."https://github.com/..."]` or
   workspace.

6. **FOD escalation trigger.** When does `tarball+narHash` stop
   being sufficient? Likely never for the horizon use-case; FOD's
   only edge would be if we wanted the horizon itself to be a
   buildable derivation that nix can fetch through binary cache
   protocols (rather than HTTP). Revisit only if a real need
   surfaces.

## 9. What an agent picking up tomorrow should do

If the design above is accepted: archive legacy `lojix` →
`lojix-archive` (local + GitHub), scaffold the new `lojix` repo
(Cargo.toml, src skeleton, beads), write the e2e test
(`cargo test --test e2e_eval`) that automates the manual steps from
§3, and replace the manual proof with that test.

If the design needs revision: comment on §7 open questions and we
redesign before any code lands.
