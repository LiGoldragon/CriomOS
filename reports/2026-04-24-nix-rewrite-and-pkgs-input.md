# 2026-04-24 — CriomOS Nix rewrite plan + pkgs-as-flake-input research

Synthesis of four parallel deep audits: the current
[modules/nixos/](../modules/nixos/) state, the original archive
([criomos-archive/nix/](../repos/criomos-archive/nix/)), canonical
modern NixOS patterns, and the technical feasibility of the user's
novel proposal — having lojix produce a second content-addressed
flake input (`pkgs`) alongside `horizon`.

## TL;DR

1. **Module rewrite is mostly mechanical, not deep.** 33 modules:
   3 deletions (the in-Nix horizon-computation layer, now obsoleted
   by horizon-rs), 3 heavy rewrites (metal/edge/nix.nix have many
   `.methods.X` accesses), 20 light edits (drop `world`/`pkdjz`,
   flatten `.methods` → flat fields), 4 unchanged. No deep redesign
   needed — the architecture is right, the code drifted from it.

2. **The `world`/`pkdjz`/`proposedCrioSphere` indirection layer is
   already conceptually replaced.** `world` was a flake-context
   aggregator; `pkdjz` was a tool/derivation factory;
   `proposedCrioSphere` was the in-Nix cluster validator. All three
   collapse into: horizon-rs (validation + projection), the lojix
   tool (artifact production), and direct `inputs.X` access (no
   indirection). Modules become `{ config, lib, pkgs, horizon, ... }`.

3. **The pkgs-as-flake-input proposal is technically clean and
   already half-supported by CriomOS** (overlays are explicitly
   disabled at [normalize.nix:131](../modules/nixos/normalize.nix#L131)).
   `lib.nixosSystem` accepts a pre-built `pkgs` arg; `nixpkgs.nixosModules.readOnlyPkgs`
   makes the override safe. But the **practical performance win is
   small** (≈5–10s per deploy on a single machine) because nix's
   eval cache already covers the unchanged-nixpkgs case. The win is
   mostly **architectural**: clean separation, pre-warming
   possible, easier to share builds across the cluster via existing
   nix binary cache mechanisms. **Recommend: file as a P3 follow-up,
   not a v1 blocker.**

## 1. Current state — audit findings

### Module-by-module (33 files in [modules/nixos/](../modules/nixos/))

**To delete (3 files; superseded by horizon-rs):**

- [zones/mkHorizonModule.nix](../modules/nixos/zones/mkHorizonModule.nix) —
  the in-Nix horizon computation (sizedAtLeast, behavesAs, isBuilder,
  trust derivation). horizon-rs does this end-to-end now.
- [zones/horizonOptions.nix](../modules/nixos/zones/horizonOptions.nix) —
  the option schema for the input cluster proposal. horizon-rs's typed
  Rust schema is the source of truth.
- [zones/default.nix](../modules/nixos/zones/default.nix) —
  drives `evalModules` over the proposal to produce horizons. Replaced
  by the `horizon` flake input.

**Heavy rewrite (3 files; many `.methods.X` accesses):**

- [metal/default.nix](../modules/nixos/metal/default.nix) — ~29
  references to `horizon.node.methods.*` (sizedAtLeast, behavesAs,
  modelIsThinkpad, hasVideoOutput, computerIs.X)
- [edge/default.nix](../modules/nixos/edge/default.nix) — ~15 such
  references
- [nix.nix](../modules/nixos/nix.nix) — heavy `.methods` use plus
  the ghost args (`world.skrips.root` at [line 104](../modules/nixos/nix.nix#L104),
  `world.pkdjz.flake-registry`, `pkdjz.exportJSON`, `hob.nixpkgs.ref`)

**Light edit (20 files; drop ghost args, flatten 1–5 `.methods`):**

normalize.nix, network/{wireguard,trust-dns,unbound,headscale,
networkd,wifi-eap,yggdrasil}.nix, router/{default,wifi-pki}.nix,
disks/{liveiso,preinstalled}.nix, users.nix, userHomes.nix,
sphere/{default,clustersModule,speciesModule}.nix, criomos.nix
(uncomment imports once the rewritten modules land).

**Unchanged (4 files):**

constants.nix, complex.nix, llm.nix, router/yggdrasil.nix,
network/tailscale.nix, disks/pod.nix.

### The horizon shape mismatch

The Nix code expects nested:

```
horizon.node.methods.sizedAtLeast.min     # OLD
horizon.node.methods.behavesAs.center
horizon.node.methods.hasVideoOutput
```

horizon-rs (Rust → JSON) emits flat with snake_case in JSON,
camelCase via `#[serde(rename_all = "camelCase")]`:

```
horizon.node.sizedAtLeast.min             # NEW (no .methods. wrapper)
horizon.node.behavesAs.center
horizon.node.hasVideoOutput
```

So every `.methods.X` access flattens to `.X`. Pure mechanical
search-and-replace once we agree on the rename — no semantic change.

### The three undefined args

From the archive audit:

- **`world`** ([criomos-archive/nix/mkWorld/default.nix:119](../repos/criomos-archive/nix/mkWorld/default.nix#L119)) —
  built by mapping `hob` (flake inputs) through `makeSpoke`. A
  recursive aggregator merging all flake inputs and computed values.
  `world.skrips.root` is the criome/skrips input evaluated as a spoke.
- **`pkdjz`** ([criomos-archive/nix/pkdjz/default.nix](../repos/criomos-archive/nix/pkdjz/default.nix)) —
  a factory for custom derivations and project utilities. Wraps
  nixpkgs + project-specific helpers. `pkdjz.exportJSON` serializes
  attrsets to files; `pkdjz.flake-registry` references the
  flake-registry input; `pkdjz.evalNixos` evaluates a NixOS config.
- **`proposedCrioSphere`** ([criomos-archive/default.nix:232](../repos/criomos-archive/default.nix#L232)) —
  built by `mkCrioSphere { uncheckedCrioSphereProposal; lib; }`,
  which evaluates two NixOS-like modules (clustersModule,
  speciesModule) over raw cluster proposals to validate and
  structure them.

All three were **plumbing for the in-Nix data pipeline**. The new
architecture moves that pipeline out: horizon-rs does validation
and projection, lojix does artifact production, and modules consume
the already-projected horizon.

## 2. Canonical NixOS module patterns we should adopt

From the canonical-patterns audit:

### specialArgs for stable global injection; mkOption for everything else

`horizon` is global, stable, and not meant to be merged or
overridden — keep it in `specialArgs`. The current
[flake.nix:46](../flake.nix#L46) already does this correctly.
Modules receive it as `{ horizon, ... }`.

For cross-cutting state that modules need to share (e.g. a shared
filesystem path table, a list of admin SSH keys), prefer
`config.criomos.X` typed options with `lib.mkOption` so they
participate in `mkMerge` / `mkOverride` semantics.

### Pre-compute horizon-derived predicates once

Today the same destructuring boilerplate is repeated across modules:

```nix
inherit (horizon.node) name system;
inherit (horizon.node.methods) sizedAtLeast behavesAs hasVideoOutput;
```

Cleaner: pre-compute a `horizonContext` attrset once and pass via
specialArgs:

```nix
# in flake.nix
specialArgs = {
  inherit horizon;
  ctx = {
    isSized = horizon.node.sizedAtLeast;
    role = horizon.node.behavesAs;
    isBuilder = horizon.node.isBuilder;
    # …
  };
};
```

Modules become tighter: `{ ctx, ... }: lib.mkIf ctx.isBuilder { ... }`.
Worth doing once after the rewrite settles.

### Role-based aggregates

CriomOS has 33 small modules — that's good (small, focused). What's
missing is **role-based aggregates**: explicit per-zone module-list
files that the top-level criomos.nix imports conditionally.

Proposed structure:

```
modules/nixos/
  criomos.nix          # entry point; imports role aggregates conditionally
  roles/
    center.nix         # imports = [ ../normalize ../nix ../users ../network … ]
    edge.nix           # imports = [ ../normalize ../nix ../users ../network ../edge ../metal … ]
    router.nix
    builder.nix
  normalize.nix
  nix.nix
  …
```

`criomos.nix` becomes:

```nix
{ horizon, ... }: {
  imports =
       lib.optional horizon.node.behavesAs.center ./roles/center.nix
    ++ lib.optional horizon.node.behavesAs.edge   ./roles/edge.nix
    ++ lib.optional horizon.node.behavesAs.router ./roles/router.nix;
}
```

This makes "what gets included on which node" a single-file
decision instead of 33 individual `mkIf`-guarded modules.

### Blueprint outputs

CriomOS-home uses blueprint to auto-discover modules and expose
`homeModules.<name>`. CriomOS could do the same: expose
`nixosModules.{criomos, network, metal, edge, router, ...}` so
consumer flakes (or future tests) can import individual modules.
Already partly true — blueprint auto-derives from
[modules/nixos/](../modules/nixos/) — but [criomos.nix](../modules/nixos/criomos.nix)
needs to be the working aggregate.

## 3. Module rewrite plan

Concrete order, smallest-blast-radius first. Each step ships
something testable.

**Step 1 — schema sweep (1 PR per 5–10 modules; no behavior change):**

Across all modules touching horizon:
- Drop `world`, `pkdjz`, `proposedCrioSphere`, `hob` from arglists.
- Replace `pkdjz.exportJSON name attrs` → `pkgs.writeText name (builtins.toJSON attrs)`.
- Replace `pkdjz.flake-registry` → `inputs.flake-registry` (after
  adding the input to flake.nix) or inline the static path.
- Replace `pkdjz.trust-dns` → `pkgs.trust-dns` if it exists in
  nixpkgs, else file a bead to package it.
- Replace `world.skrips.root` → either inline the script content
  (it's small) or pull `skrips` in as a flake input.
- Flatten `horizon.node.methods.X` → `horizon.node.X` everywhere.
  (Mechanical sed; verified by horizon-rs JSON shape.)

**Step 2 — delete the obsolete zones layer:**

Remove [zones/mkHorizonModule.nix](../modules/nixos/zones/mkHorizonModule.nix),
[zones/horizonOptions.nix](../modules/nixos/zones/horizonOptions.nix),
[zones/default.nix](../modules/nixos/zones/default.nix), and
[sphere/](../modules/nixos/sphere/) entirely. horizon-rs does this
work. Anything still referencing them gets fixed in Step 1.

**Step 3 — wire criomos.nix:**

Make [criomos.nix](../modules/nixos/criomos.nix) actually import
the modules (currently `imports = []`). Start minimal — just
normalize.nix + nix.nix — and verify
`nix build .#nixosConfigurations.target.config.system.build.toplevel`
gets further than the assertion failure (i.e., reaches a real
fileSystems error from disks/, not a missing-arg error).

**Step 4 — role aggregates:**

Create [roles/](../modules/nixos/roles/) per the pattern above.
Drives module inclusion by `horizon.node.behavesAs`.

**Step 5 — `horizonContext` synthesis:**

Add the pre-computed predicate attrset at the flake-eval boundary;
update modules to consume `ctx` instead of repeated destructuring.

Estimate: Steps 1–3 are 1–2 days of careful but mostly mechanical
work; Steps 4–5 are polish.

## 4. The novel proposal: pkgs as a second content-addressed flake input

The user's idea: lojix produces TWO content-addressed flake inputs
to CriomOS — `horizon` (per-deploy) and `pkgs` (per
(nixpkgs-rev, system) tuple). The pkgs flake exposes a
pre-instantiated `pkgs` attrset; CriomOS feeds it into
`lib.nixosSystem` via the `pkgs` arg, skipping the internal
`import nixpkgs { … }` pass.

### Technical feasibility — green

`lib.nixosSystem`'s signature ([nixos/lib/eval-config.nix](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/lib/eval-config.nix))
includes `pkgs ? null`. When provided, the internal `defaultPkgs`
in [nixos/modules/misc/nixpkgs.nix](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/misc/nixpkgs.nix)
is bypassed — the supplied pkgs is used directly.

There's a documented gotcha: by default `nixpkgs.config` /
`nixpkgs.overlays` options become silently no-op when `pkgs` is
supplied. The fix is to also import `nixpkgs.nixosModules.readOnlyPkgs`,
which turns those options into errors (loud failure on
misconfiguration).

CriomOS is already half-prepared for this: [normalize.nix:131](../modules/nixos/normalize.nix#L131)
forces `nixpkgs.overlays = mkOverride 0 [ ]`. So overlay handling
isn't a complication for our case.

### Lojix flow (if adopted)

```
lojix deploy --cluster goldragon --node tiger
  │
  ├── HorizonProjector  → horizon.json
  │       └── HorizonArtifact  → /nix/store/<H1>-…/{flake.nix, horizon.json}
  │
  └── PkgsArtifact       (NEW actor)
          ├── pin nixpkgs rev (from a config or flake registry)
          ├── derive system from horizon.node.system
          ├── write a tiny flake:
          │     { inputs.nixpkgs.url = "github:NixOS/nixpkgs?rev=<rev>";
          │       outputs = inputs: {
          │         pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
          │       }; }
          └── write to ~/.cache/lojix/pkgs/<nixpkgs-rev>-<system>/
                                                   ↑ stable per (rev, system)

Then:
  nix build … --flake github:LiGoldragon/CriomOS#target \
              --override-input horizon path:<horizon-dir> \
              --override-input pkgs    path:<pkgs-dir>
```

CriomOS's flake.nix changes:

```nix
inputs.pkgs.url = "path:./stubs/no-pkgs";   # default stub throws

outputs = inputs: …
  let pkgs = inputs.pkgs.pkgs; in
  nixpkgs.lib.nixosSystem {
    inherit pkgs;                           # supplied → skip internal import
    specialArgs = { inherit horizon; };
    modules = [ inputs.nixpkgs.nixosModules.readOnlyPkgs
                inputs.self.nixosModules.criomos ];
  };
```

### What we'd actually gain

The agent-3 research gives the honest answer: the eval-cache speedup
on a single machine is small (≈5–10s per `nixos-rebuild`), because
nix already caches per-flake-input narHash and unchanged-nixpkgs
already hits cache.

The real wins are **structural**:

- **Cleaner cache invalidation boundary.** Today, any flake input
  change can theoretically invalidate the whole eval. With
  pkgs-as-input, horizon changes don't touch the pkgs path; pkgs
  changes don't touch the horizon path. Each axis caches
  independently.
- **Pre-warming.** lojix can produce + warm the pkgs cache once
  before any deploy starts; subsequent deploys (potentially many,
  in parallel across the kriom) all see warm cache.
- **Shareable build outputs.** Different clusters / different lojix
  invocations / different machines that pin the same nixpkgs-rev all
  get the same store path for the pkgs flake input → identical
  derivation hashes downstream → existing nix binary cache
  mechanisms share builds. This already works, but the explicit
  pkgs flake makes it crisper.
- **Decoupled nixpkgs upgrade.** A nixpkgs revision bump is a
  single, content-addressed change; no other CriomOS code moves.

### What we'd give up

- **One more flake input to manage.** The pkgs flake has to be
  generated by lojix and the override has to be passed every time
  (or defaulted via a pinned nixpkgs in the stub).
- **`nixpkgs.config` / `nixpkgs.overlays` lock down.** Adding
  `readOnlyPkgs` is correct but rigid — any module trying to set
  these will hard-error. Fine for CriomOS's current "no overlays"
  stance; would need revisiting if that changes.
- **Local-dev iteration friction.** `nix flake update` on the
  pkgs flake means rerunning lojix to regenerate the artifact.
  Acceptable since nixpkgs bumps are infrequent.
- **No automatic cross-machine eval-cache sharing.** The eval
  cache is local SQLite (`~/.cache/nix/`); content-addressing
  doesn't propagate the cache itself, only the input identity. Each
  machine evaluates pkgs once, then locally caches. (Build outputs
  do share via binary cache as today.)

### Recommendation

**Defer to v2; file as P3 in lojix.** The architecture is sound and
worth doing, but it's not a v1 blocker. The current design (horizon
as the only override) already proves the cache property. Adding a
second axis is a clean extension once the module rewrite lands and
deploy frequency makes the marginal speedup worth chasing.

When we do it: name the lojix actor `PkgsArtifact`, mirror the
HorizonArtifact pattern, cache at `~/.cache/lojix/pkgs/<rev>-<system>/`
for stability across runs, and emit the override URI alongside the
horizon's. CriomOS gains the pkgs input and the readOnlyPkgs
import — total Nix-side change is ≈10 lines.

## 5. Bead changes

**Existing beads to keep open / adjust:**

- [`CriomOS-52j`](../.beads/) (P1, "Adapt copied NixOS modules") —
  this report is the design for it. Sub-tasks below should be filed
  as children once the structure is agreed.

**Suggested new beads (in CriomOS):**

- `CriomOS-???` P0 — Step 1: schema sweep (drop world/pkdjz/hob/
  proposedCrioSphere; flatten `.methods` → flat fields) across all
  modules. Mechanical pass; ≤ 1 day.
- `CriomOS-???` P0 — Step 2: delete zones/ and sphere/ (horizon-rs
  obsoletes them).
- `CriomOS-???` P0 — Step 3: wire criomos.nix imports; smallest
  set that lets `nix eval system.build.toplevel.drvPath` succeed
  (or fail on a real config error, not a missing arg).
- `CriomOS-???` P1 — Step 4: introduce roles/ aggregates driven by
  `horizon.node.behavesAs`.
- `CriomOS-???` P2 — Step 5: pre-compute `horizonContext` and pass
  alongside horizon.

**Suggested new bead in lojix:**

- `lojix-???` P3 — `PkgsArtifact` actor: produce a content-addressed
  pkgs flake (per (nixpkgs-rev, system)) and emit a second
  `--override-input pkgs ...`. CriomOS additionally takes a `pkgs`
  flake input + imports `nixpkgs.nixosModules.readOnlyPkgs`.
  Reference this report.

## 6. Open questions

1. **Where does `nixpkgs-rev` come from for the pkgs flake?** Three
   options:
   - **Pinned in lojix config** (a single `~/.config/lojix.toml` or
     similar). Simplest; one source of truth across the kriom.
   - **Discovered from CriomOS's own flake.lock.** Works but creates
     a dependency cycle (lojix needs to pre-eval based on what
     CriomOS will request).
   - **Per-cluster** in goldragon's `datom.nota`. Keeps everything
     in one declarative source. Probably right long-term.
   Decision needed before the lojix PkgsArtifact bead lands.

2. **`flake-registry` and `skrips` dependency.** The archive's
   `world.pkdjz.flake-registry` and `world.skrips.root` need
   replacements. Inline the relevant pieces, or add proper flake
   inputs. The skrips repo (https://github.com/criome/skrips) is
   small and probably worth ingesting directly rather than carrying
   as an input.

3. **Do we keep the input-validation layer?** The archive's
   sphere/{clustersModule, speciesModule}.nix validated the raw
   cluster proposal. horizon-rs does this end-to-end now. Confirm
   nothing else depends on these schemas before deletion.

4. **`horizonContext` shape.** Worth bikeshedding once before
   pinning — what predicates / fields belong in the pre-computed
   context vs. left as raw `horizon.node.X`? Probably the
   AtLeast/BehavesAs/TypeIs structs.

5. **`readOnlyPkgs` rigidity.** Are we sure the `no overlays` stance
   holds? If any future module wants to override (e.g., a custom
   patch on a nixpkgs package), readOnlyPkgs will reject it loudly.
   Plan: yes, keep the no-overlays stance — overrides go via separate
   `pkgs/X.nix` blueprint packages or new flake inputs, not via
   nixpkgs overlays.

## 7. What an agent picking up tomorrow should do

If the rewrite plan in §3 is accepted: file the P0 beads and start
Step 1 (schema sweep) on a small batch of network/ modules to
validate the mechanical-pass approach end-to-end (commit, eval, see
the next failure surface, iterate). Step 2 (delete zones/) is
trivially safe.

If the pkgs-as-input proposal in §4 is accepted as v2 work: file
the lojix P3 bead with this report as the reference, and decide
the (nixpkgs-rev, system) source per open question 1.

If either needs revision: comment on the open questions and we
redesign before any code lands.
