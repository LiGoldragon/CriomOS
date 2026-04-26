# Archive retirement — what's actually missing

Question from Li: "are we missing anything to switch production to the
new CriomOS? we could fix [the audit carry-overs] later. then I
wouldn't have to maintain criomos-archive."

This report scopes only the **hard blockers** between today and "all 5
nodes deploy from new CriomOS, archive read-only." Per Li's framing,
CriomOS-1ey (security carry-overs from archive) and the deferred
designs (CriomOS-bb5, -4xw, -og4) are explicitly **not** blockers —
they get fixed after the switch.

## Eval state — confirmed in 0022

| Node | State | Type of gap |
|---|---|---|
| ouranos | green (drvPath emitted) | — |
| tiger | green (drvPath emitted) | — |
| zeus | green (drvPath emitted) | — |
| balboa | green-at-module-level | needs aarch64 builder for full eval |
| prometheus | green-at-module-level | LLM FOD store path needs realisation |

Eval-only is not deploy-readiness, but it is the floor.

## Real blockers between green eval and "switch to production"

### 1. Build has never actually been run from new CriomOS
**On any node.** Eval emits a drvPath; `nix build` realises it.
Realisation is where missing FODs, broken cross-references, and
overlay surprises actually surface. Cheapest test:
`lojix build --cluster goldragon --node ouranos --source
/home/li/git/goldragon/datom.nota`. ~1-3 hrs first time (incremental
cache reuse after).

### 2. Deploy has never actually been run from new CriomOS
**On any node.** `lojix deploy` is the path that must subsume the
archive's `nixos-rebuild switch` workflow. First test should be
ouranos (Li's daily driver, T14, on-network, lowest blast radius).
Failure modes to watch:
- streaming: lojix's subprocess output not forwarded → looks frozen
  for tens of minutes during build steps (referenced in reports as
  the lojix-auy concern).
- atomicity: if lojix writes deploy artifacts non-atomically, a
  crash mid-flight can leave the node half-switched (lojix-cv1).

The first deploy will tell us whether these are real blockers or
theoretical. If they bite, fix before tiger/zeus.

### 3. `home-f68` (P1 in CriomOS-home beads) — still open
"Adapt verbatim home modules to consume new horizon schema." The
home aggregate is wired and eval-green ([0022](0022-trim-extract-outcome.md)),
but the verbatim-imported modules under
`CriomOS-home/modules/home/` may still reference old horizon shape
(pre-Mg→AtLeast or pre-camelCase). Eval doesn't catch logic bugs
where a field is read but always returns null/false. Worth a
walkthrough before depending on a deploy.

### 4. balboa — environmental, defer or builder
balboa is a rock64 SD-card edge node (Arm64). New CriomOS doesn't
have an aarch64 builder configured. Two paths:
- **Defer**: balboa keeps booting from its last archive-built image
  until an aarch64 builder is set up. Archive doesn't actually
  redeploy balboa often — SD cards are written rarely.
- **Set up aarch64 builder**: nixpkgs cross-compile or a remote
  Arm64 builder. ~3-6 hrs.

If Li's goal is "stop maintaining archive *for redeploys*," defer
balboa — it doesn't get redeployed often enough to keep archive
alive for it.

## What's NOT a blocker

- **Feature parity**: confirmed in 0022 — every module Li actually
  uses (router, complex.nix WiFi PKI, llm services, NordVPN,
  WireGuard, normalize, users, edge, metal subsystem) is ported and
  wired. The only feature gap is what's not in datom.nota.
- **CriomOS-1ey audit items**: SEC-1/2/3 + MOD-1/2/3 — production
  works without these fixed. Fix them post-switch.
- **CriomOS-bb5 / -4xw / -og4**: all marked deferred, none gate a
  deploy.
- **emacs / criomos-emacs**: bare-min neovim is in the home aggregate;
  vscodium is the daily editor; emacs work is its own track.

## Critical path to retire archive

Cheapest ordered path:

1. **Walk through home-f68** (~1-2 hrs). Verify the verbatim home
   modules under `CriomOS-home/modules/home/` actually use the new
   horizon schema correctly. Close the bead or fix what surfaces.

2. **`lojix build --node ouranos`** (~1-3 hrs). First real build
   from new CriomOS. If it succeeds, you have an artifact. If it
   surfaces an issue, you're in the right repo to fix it.

3. **`lojix deploy --node ouranos`** (~1-3 hrs first time). Daily
   driver, on-network, easiest to recover. If streaming /
   atomicity bite (lojix-auy/cv1), fix in lojix and retry.

4. **Build + deploy tiger and zeus** (~1-2 hrs each, mostly cached
   after ouranos). These are headless / low-touch nodes — verify
   via SSH that they boot + their services come up.

5. **Build + deploy prometheus**. FODs already realised on the box
   (model files exist in /nix/store with matching hashes), so no
   fetch needed — same shape as tiger/zeus.

6. **balboa**: defer indefinitely OR set up aarch64 builder.
   Either way, archive is no longer needed for the other 4 nodes.

After 1-5 land, **archive can flip to read-only** — kept for
historical reference, no longer maintained. balboa keeps its archive
image until an aarch64 path exists.

Realistic wall-clock for the ouranos-first sequence: **half a day to
a day** of focused work, mostly waiting on builds. The unknown
unknown is whether lojix's streaming / atomicity actually bite during
deploy — those could add hours if they do. None of it is multi-day.

## What would change this analysis

- A discovered feature in archive that was never ported (would surface
  during the home-f68 walk-through or first deploy).
- lojix turning out to have deeper plumbing gaps than streaming +
  atomicity (e.g. the action-override path doesn't actually invoke
  `nixos-rebuild`, only emits a plan).
- A node whose build pulls something that's been removed from current
  nixpkgs (would surface in step 2).

All three are "discover during the first run, fix in-place" items —
not pre-blockers.
