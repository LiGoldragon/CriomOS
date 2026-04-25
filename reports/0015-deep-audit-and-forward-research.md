# 2026-04-25 — deep audit + forward research

Three parallel sub-agents covered: (1) ecosystem state audit, (2)
strategic forward direction, (3) risk + cross-repo coherence audit.
This report consolidates the three.

## TL;DR

The ecosystem is **eval-viable but not yet deploy-viable**. Phase 8
module wiring is done; `lojix eval` produces real toplevel drvPaths
for all 5 nodes; crane+fenix builds for all 4 Rust crates pass on
nixos-unstable head. The next leveraged step is **operational
maturity in lojix** (`lojix-auy`, `lojix-cv1`), then a **first real
deploy** of one node, then everything else gets cheaper.

## Current state

### Working end-to-end
- **horizon-rs schema** fully populated: `Magnitude::Large` ladder,
  `AtLeast` flat fields, `Node.{wantsPrinting, wantsHwVideoAccel}`,
  `Machine.{chipGen, ramGb}`. JSON output is camelCase. nota positional
  records still parse with implicit defaults at trailing fields.
- **3-flake architecture** (system + pkgs + horizon as content-addressed
  flake inputs). Cache property holds across runs and machines.
- **`lojix eval`** against goldragon: all 5 remaining nodes (balboa,
  ouranos, prometheus, tiger, zeus) produce real drvPaths.
- **CriomOS Phase 8 wiring**: every module that should be in
  `criomos.nix` is there (preinstalled, normalize, nix, complex, llm,
  users, the network aggregator, edge mkIf-edge, userHomes, metal
  mkIf-bareMetal, router mkIf-router with wifi-pki + yggdrasil
  sub-imports). `disks/{liveiso,pod}` correctly excluded as
  alt-targets. trust-dns deleted as dead code.
- **All 4 Rust crates** (lojix, horizon-rs, clavifaber, brightness-ctl)
  on crane + fenix per [tools-documentation/rust/nix-packaging.md](repos/tools-documentation/rust/nix-packaging.md).
  `nix build .#packages.x86_64-linux.default` clean across all four.
- **AGENTS.md / CLAUDE.md** convention applied (CLAUDE.md is a
  one-line shim everywhere). Generic agent rules migrated from
  mentci-next.

### Stubbed or partial
- **CriomOS-home aggregate** ([modules/home/default.nix](repos/CriomOS-home/modules/home/default.nix))
  imports only `niri-flake.homeModules.config` conditionally — the real
  home modules (base, vscodium, profiles, neovim, emacs) exist but are
  not wired into the aggregate. Tracked as `home-tcj` (P1).
- **`pkdjz.mkEmacs`** is the last legacy ghost-arg, in
  `CriomOS-home/modules/home/emacs/emacs/default.nix`. Blocked on
  `criomos-emacs` scaffold (`emacs-plb`, blocked).
- **criomos-cfg + criomos-hw-scan** — designs written, beads filed
  (`CriomOS-bb5` P2, `CriomOS-4xw` P3); no implementation yet.
- **Closure shrinkage** — audit identified ~1.5–2.5 GB recoverable;
  HIGH-tier mechanical fixes (gnome stack from `atLeastMin` →
  `atLeastMed`, etc.) are NOT yet landed.
- **Display fields** (`scale_percent`, `display_x_pixels`,
  `display_y_pixels`) deferred until the compositor module wants them.

### Surprisingly missing
- No working `nix flake check` outputs in CriomOS — `checks/` dir has
  stub files with syntax errors. Rust crates also lack the wiring
  (only lojix has it, via crane.cargoTest). No CI gate anywhere.
- No standalone validator for `goldragon/datom.nota` outside of an
  in-process horizon projection.
- No deployment rollback mechanism beyond NixOS's built-in generation
  selector.
- No telemetry / structured logging in any of the Rust crates.

## Strategic forward direction

Agent ranked 7 candidate paths by leverage. Recommended sequence:

| Order | Path | Days | Unlocks |
|-------|------|------|---------|
| 1 | **A — operational maturity** (lojix-auy streaming + lojix-cv1 atomic write + lojix-d56 publish) | ~3 | All other paths |
| 2 | **F — first real deploy** (`lojix switch ouranos`) | ~2–3 | Surfaces real-world breakage; gives concrete numbers for C |
| 3 | **D — CriomOS-home aggregate** (home-tcj) | ~1–2 | Home-manager testable end-to-end; closes the test-harness gap |
| 4 | **B — schema completeness** (deferred horizon-rs fields, nota validator) | ~2–3 | Faster failure on bad proposals; more derivable fields |
| 5 | **C — closure shrinkage** | ~2–4 | Real disk/bandwidth wins; benefits from F's data |
| 6 | **E — tooling diversification** (criomos-hw-scan, criomos-cfg) | ~3–4 each | Operational insight + drift detection |
| 7 | **G — distributed binary cache** | ~2–3 | Multi-node deploy efficiency; only matters at scale |

**Why A first**: every other path depends on a deploy mechanism that
won't silently buffer or crash mid-write. The current "no timeout"
band-aid (just landed) means *long deploys complete eventually but
the operator has zero visibility into progress*. That's not
deployment-viable.

**Why F before C**: closure shrinkage benefits from real measured
deploy-time / download-time numbers, which only F produces.

## Top risk vectors (silent breakage)

Three risks that warrant addressing **before** the next big rewrite
batch. Detection + mitigation per risk:

### R1. Positional nota schema drift (silent breakage)
Every `Machine` and `NodeProposal` in goldragon's `datom.nota` is
positional. If horizon-rs reorders / inserts a struct field
mid-struct (rather than at the end), every existing nota file fails
to parse with a confusing "expected X, found Y" error.

- **Existing discipline**: comments at
  [horizon-rs/lib/src/proposal.rs:67-71](repos/horizon-rs/lib/src/proposal.rs#L67-L71)
  and [machine.rs:24-31](repos/horizon-rs/lib/src/machine.rs#L24-L31)
  enforce "add fields at the end". No compile-time check.
- **Mitigation**: add a horizon-rs integration test that loads
  `goldragon/datom.nota` (or a fixture mirror) on every CI run.
  Field reorder = test red.

### R2. Cargo git-URL hash mismatch on update (loud but opaque)
`lojix/flake.nix` `vendorCargoDeps.outputHashes` keys lock the per-rev
sha256 for git-URL deps (horizon-lib, nota-serde, nota-serde-core).
Bumping `cargo update` advances the rev → hash mismatch → cryptic
crane error.

- **Existing discipline**: every recent lojix Cargo.lock bump comes
  with a manual outputHashes update.
- **Mitigation**: document the workflow in
  [tools-documentation/rust/nix-packaging.md](repos/tools-documentation/rust/nix-packaging.md)
  under "Updating git-URL deps". Optional: small script that
  diff-detects new revs and prints the `nix-prefetch-git` commands.

### R3. Module wiring side effects (silent activation)
The network aggregator pulls in `unbound`, `yggdrasil`, `tailscale`,
`headscale`, `nordvpn`, `wifi-eap`, `networkd`, `wireguard` for every
node. Each module gates internally via `mkIf` against
`behavesAs.{router|center|edge}` or specific node-name checks. If a
gate is wrong (e.g. unbound starts listening on link-local on a
non-router by accident), no test catches it.

- **Mitigation**: an assertion module in CriomOS that, per node,
  checks `services.unbound.enable → behavesAs.router || behavesAs.center`
  and similar invariants. Failures surface at `lojix eval` time.

## Disagreements between agents — to verify

- **Agent 1** says `home-f68` is open (P1) for adapting verbatim home
  modules. `home-tcj` covers wiring. Verify these are still distinct
  and not mergeable.
- **Agent 1** lists `gold-vja` as "decide fate of asklepios and
  eibetik". Those node names don't appear in the current
  `datom.nota`. Either that bead is stale or those are explicitly-
  removed nodes still tracked for future re-add. Worth either closing
  or re-titling.
- **Agent 1** counts Phase 8 as "12/15 modules wired"; my actual count
  this session was 13 modules + the network aggregator (which itself
  bundles 8 sub-modules). The agent likely missed router/yggdrasil
  sub-imports. Number is cosmetic; the substantive answer is "Phase 8
  is done, no more pending modules to wire".
- **Agent 1** (state) and **Agent 3** (risk) both flag lojix-auy as
  blocking. Agent 1 says my recent commit replaced the 900s timeout
  with None, which "fixes" the timeout. Agent 3 says the underlying
  silent-buffering issue persists. Both correct — the timeout band-aid
  unblocks waiting, but live progress is still buffered until exit.
  The real `lojix-auy` work (subprocess output streaming via
  `tokio::process::Command::stdout(Stdio::piped()) + lines()`) is
  still pending.

## Reports inventory: candidates for deletion

Per the "delete wrong reports — don't banner them" rule. Reports that
are now superseded by later work:

- [reports/0001-ecosystem-audit.md](reports/0001-ecosystem-audit.md)
  — first ecosystem-wide audit; superseded by
  [reports/0009-post-compact-audit.md](reports/0009-post-compact-audit.md)
  and the later ones.
- [reports/0003-nix-rewrite-and-pkgs-input.md](reports/0003-nix-rewrite-and-pkgs-input.md)
  — explicitly superseded by
  [reports/0004-3flake-implemented.md](reports/0004-3flake-implemented.md)
  (its own header notes the wrong initial pkgs-as-flake interpretation).

These two should be removed in the next housekeeping pass.

## Concrete next-action plan (next few days)

1. **lojix-auy proper fix**: redesign the build actor to spawn nix
   via `tokio::process::Command` with `Stdio::piped()`, read stdout
   line-by-line, send each line as a `BuildProgress` message back to
   the coordinator (per the prior research). Removes the band-aid
   `None` timeout because progress messages keep the actor alive.
   ~1 day.
2. **lojix-cv1**: switch artifact write to `tempfile + persist()` for
   atomic-rename semantics. ~½ day.
3. **First real deploy**: `lojix switch` to ouranos. Likely surfaces
   ~2–5 small breakages. ~1–2 days of iteration.
4. **R1 mitigation**: add a horizon-rs integration test for
   `goldragon/datom.nota`. ~1 hour.
5. **R3 mitigation**: write the per-node assertion module. ~2 hours.
6. **Housekeeping**: delete the two superseded reports.

After that, reassess: `home-tcj` next (D), then schema/closure work
in parallel, with criomos-hw-scan + criomos-cfg as background
side-projects.
