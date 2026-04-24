# 2026-04-24 — CriomOS ecosystem audit

State of the rewrite across all sibling repos as of end-of-day
2026-04-24. Run by four parallel audits over the symlinked repos at
[repos/](../repos/).

## TL;DR

Rust core stack is **operational**. Data layer is **operational**.
NixOS overlay (CriomOS itself) is **scaffold and won't evaluate** —
every P0 blocker on the platform side is open. CriomOS-home and
CriomOS-emacs are also pure scaffold; the two Rust side-tools
(clavifaber, brightness-ctl) build but haven't been Mentci-restyled.

## Per-repo state

| Repo | State | Builds? | Open beads | Key gap |
|---|---|---|---|---|
| [horizon-rs](../repos/horizon-rs/) | Phase 1 done | ✓ tests pass | 6 (P1×2, P2, P3×2, P4) | `--format json` flag (`horizon-j6b` P1) |
| [nota](../repos/nota/) | Spec complete | n/a (spec-only) | 1 (P2: file-ref notation) | — |
| [nota-serde](../repos/nota-serde/) | Production | ✓ 93 tests pass | 0 | `#[serde(flatten)]` forbidden (documented) |
| [goldragon](../repos/goldragon/) | Real data, in nota | n/a (data) | 4 (P2, P3×2, P4) | Per-user `Style`, `prometheus` ssh key |
| [CriomOS](.) | **Phase 0 scaffold; eval-broken** | ❌ | 4 (P0×2, P1, P2) | `mkHorizon` stub, `crioZones` `{}`, undefined `world`/`pkdjz`/`proposedCrioSphere` in 33 modules |
| [CriomOS-home](../repos/CriomOS-home/) | Scaffold | flake.nix has dead URL | 3 (P1×2, P2) | `homeModules.default` empty; `claude-for-linux` input 404 |
| [CriomOS-emacs](../repos/CriomOS-emacs/) | Scaffold | n/a | 2 (P2, P3) | `mkEmacs` not converted to blueprint package |
| [clavifaber](../repos/clavifaber/) | Compiles | ✓ 6 tests pass | 2 (P3, P4) | Mentci restyle pending |
| [brightness-ctl](../repos/brightness-ctl/) | Compiles | ✓ (no tests) | 1 (P3) | Mentci restyle pending; no test coverage |

## Critical-path queue (do in this order)

1. **`horizon-j6b` (P1, ~2 hrs)** — implement `--format nota|json` in
   `horizon-cli`, with **JSON as default** (Nix consumers can't read
   nota). Trivial: add `serde_json` to `cli/Cargo.toml`, clap enum
   `Format::Json | Format::Nota`, branch in `main`.

2. **`CriomOS-lyc` (P0)** — wire `lib.mkHorizon` to invoke `horizon-cli
   --format json` via IFD; parse with `builtins.fromJSON`. Currently
   throws "not yet implemented" at [lib/default.nix:94-100](../lib/default.nix#L94).
   Needs `goldragon` as a flake input (or path attr) so `datom.nota`
   is reachable.

3. **`CriomOS-cal` (P0)** — implement `crioZones.nix`. Currently `{ }`.
   Should iterate every flake input that exposes `NodeProposal` (or
   the new equivalent path attr) and produce
   `crioZones.<cluster>.<node>.{os,fullOs,vm,home,deployManifest}`.

4. **`CriomOS-52j` (P1) — module redesign, not adapt.** All 33 modules
   under [modules/nixos/](../modules/nixos/) reference `horizon.node.methods.X`
   (old API) and undefined closure args `world`, `pkdjz`,
   `proposedCrioSphere`. Per user's 2026-04-24 directive: **rewrite,
   don't patch**. `world` / `pkdjz` indirection gets dropped; modules
   consume horizon directly. `proposedCrioSphere` semantics: TBD —
   most likely a new horizon input type (see open question below).
   Estimated 2-3 FTE days per zone (`metal/`, `edge/`, `router/`,
   `sphere/`, `zones/`, `network/`).

5. **`home-tcj` (P1)** + **`home-f68` (P1)** — implement
   CriomOS-home's `homeModules.default` aggregate and adapt the
   verbatim home modules to the new horizon shape. Same redesign
   spirit as CriomOS-52j.

## Risks and surprises

- **Missing flake input `llm-agents`** referenced from
  [modules/nixos/normalize.nix:118](../modules/nixos/normalize.nix#L118)
  but not declared in [flake.nix](../flake.nix). Will fail at first
  eval.
- **`checks/librist.nix` syntax errors** at lines 33 (unescaped `$`)
  and 45 (empty `writeScriptBin ""` name). `nix flake check` will
  reject.
- **CriomOS-home `claude-for-linux` input URL returns 404** (per recent
  flake.nix commit). Blocks any flake-input update on that repo.
- **Module-level undefined closure args** (`world`, `pkdjz`,
  `proposedCrioSphere`) — eval will fail with "variable is not
  defined" the moment any of the 33 modules is instantiated.
- **3 nodes excluded from `goldragon/datom.nota`** — `prometheus` (no
  ssh host pubkey), `asklepios` and `eibetik` (no `io`, no `pubKeys`).
  All tracked in goldragon beads. CriomOS will not be able to deploy
  those three until data is filled in.
- **`xerxes` `linkLocalIps[0].iface` was guessed** as `enp0s25` from
  legacy `species=ethernet`; user verification needed (`gold-jsm` P3).

## Wins this session (2026-04-23 → 2026-04-24)

- **nota** spec migrated to positional records (drop `=`, newtypes
  wrap, multi-field tuple structs forbidden); **nota-serde** rewrite
  in lockstep; horizon-rs builds clean against new nota-serde.
- **horizon-rs** YGG_PUBKEY_LEN bugfix: 128 → 64 (real ed25519 length).
  Was previously rejecting all real Yggdrasil pubkeys; only worked
  because the deleted maisiliym fixture had been doubled to fit.
- **horizon-rs** `maisiliym.nota` fixture and `projection.rs`
  integration tests removed. No data is duplicated between repos
  anymore — goldragon owns the cluster data.
- **goldragon** rewritten as pure data: `datom.nix` and `flake.nix`
  removed; `datom.nota` lands real production data for 6 nodes. All 6
  viewpoints project cleanly through `horizon-cli`.
- **CriomOS** scrubbed of `maisiliym` mentions (8 lines across README,
  flake.nix, deploy scripts → `goldragon`).
- **Memory + style.md** alignment fixed: thiserror is canonical, no
  more "manual Error enum" guidance; edition 2024 (not 2021).
- **Beads hygiene**: 4 closed (`horizon-869`, `horizon-bsj`,
  `gold-lu7`, `gold-21l`), 4 new tracking beads on goldragon, all
  bead descriptions trimmed to one-liners per user feedback.

## Open questions / deferred decisions

1. **Newtype transparent-vs-wrapped.** Current `string_newtype!` macro
   in [horizon-rs/lib/src/name.rs:11](../repos/horizon-rs/lib/src/name.rs#L11)
   uses `#[serde(transparent)]`, which gives bare-string serialization
   (matches current `datom.nota`). The new nota spec says newtypes
   wrap as `(NodeName foo)`. Working as-is, but conceptually
   inconsistent with the spec.

2. **`proposedCrioSphere` semantics.** What did this provide in the
   archive? Same redesign treatment as `world`/`pkdjz` (drop entirely)
   or promote to a new horizon input type (like `iface`)?

3. **horizon-rs integration test loading mechanism.** User wants tests
   to read goldragon's `datom.nota` directly (no duplicated fixture).
   Three candidates earlier surfaced: (a) flake input + env var with
   sibling-path fallback, (b) sibling-path only, (c) end-to-end
   process test. No decision yet.

4. **Style guide gaps.** No guidance on panics, logging (tracing/log),
   feature flags, or async patterns. Add when the first concrete
   need surfaces, not preemptively.

5. **Per-user `Style`** in goldragon (currently all `Emacs`) — needs
   real per-user data (`gold-a1u` P4).

## What an agent picking up tomorrow should do

Land `horizon-j6b` (`--format json` default in horizon-cli) — it's
the smallest atomic unblock and CriomOS-lyc literally cannot proceed
without it. After that, the IFD chain becomes the next focus and
unlocks the actual platform work.
