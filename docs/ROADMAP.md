# CriomOS — Roadmap

CriomOS is network-neutral; CriomOS-home owns the home profile.
The horizon schema and projection logic now live in `horizon-rs`
(see [/home/li/git/horizon-rs/docs/DESIGN.md](/home/li/git/horizon-rs/docs/DESIGN.md)).

Active work is tracked in beads — `bd list --status open`. The list
below is a high-level porting order; per-task detail lives in the
beads issues it points to.

## Phase 0 — scaffold (done)

- [x] `flake.nix` — blueprint + custom `crioZones` output
- [x] `crioZones.nix` — placeholder
- [x] `devshell.nix`, `formatter.nix`
- [x] `lib/default.nix` — criomos-lib namespace + `mkHorizon` stub
- [x] `modules/nixos/criomos.nix` — empty aggregate
- [x] `docs/{ROADMAP,GUIDELINES,NIX_GUIDELINES}.md`, `AGENTS.md`, `README.md`

## Phase 1 — wire horizon-rs

`horizon-rs` Phase 1 is implemented (typed schema + `horizon-cli` that
reads cluster proposal nota on stdin and emits enriched horizon nota
or JSON via `--format json`). Wiring it into CriomOS:

- [ ] `CriomOS-lyc` — implement `lib.mkHorizon` via IFD against
      `horizon-cli --format json`, reading the goldragon proposal.
- [ ] `CriomOS-cal` — implement `crioZones.nix` (network-neutral
      cluster discovery + per-node `os/fullOs/vm/home/deployManifest`).

Cross-tracked in horizon-rs as `horizon-30u`.

## Phase 2 — adapt copied NixOS modules

- [ ] `CriomOS-52j` (epic) — `modules/nixos/*` are verbatim copies from
      `criomos-archive` with only the `preCriome → pubKey` rename
      applied. They still reference `horizon.node.methods.X`; the new
      shape is flat (`horizon.node.X`). Per-module ports needed —
      see the bead for the list.

## Phase 3 — audit fixes

- [ ] `CriomOS-1ey` (epic) — security + module-shape audit items from
      `criomos-archive/docs/AUDIT-2026-04-17.md`. Done during the
      relevant Phase 2 module ports rather than as a separate pass.

## Phase 4 — CriomOS-home wiring

Tracked in `CriomOS-home`'s own `docs/ROADMAP.md`. Blocking
dependencies on this repo:

- [ ] CriomOS consumes `inputs.criomos-home.homeModules.default` in
      `crioZones.<cluster>.<node>.home.<user>`.

## Phase 5 — cutover

- [ ] Goldragon `datom.nota` lands (`gold-lu7` / `gold-21l`).
- [ ] Every host on CriomOS for ≥ 14 days.
- [ ] Archive remains read-only at `criomos-archive`.

## Side-repo splits (status)

- [x] `github:LiGoldragon/clavifaber` — split out.
- [x] `github:LiGoldragon/CriomOS-emacs` — split out (consumed by
      CriomOS-home, not by CriomOS directly).
- [x] `github:LiGoldragon/brightness-ctl` — split out, consumed via
      flake input.
- [x] `github:LiGoldragon/horizon-rs` — split out, schema + CLI.

## Open design questions

- **Cluster discovery signature.** `discoverClusters` in
  `lib/default.nix` filters inputs by `? NodeProposal`. Works today;
  revisit if a cluster proposal's shape grows richer.
- **capnp:** the `criomos-archive/capnp/` files are concept-only and
  not exercised. Decision pending: delete, or auto-derive from
  horizon-rs's Rust types. Leaning delete.
