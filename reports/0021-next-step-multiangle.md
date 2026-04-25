# Next-step research — multi-angle, with a skeptical lens

Post-compact (after 0020). The mechanical "next concrete action" listed
in 0020 is **vim-plugin cleanup** (`CriomOS-6u6`). Before just doing it,
this report lays out the angles so the choice is deliberate.

## Where we actually are

- `home-tcj` architecture fix landed: flake-level wrapper in
  `CriomOS-home/flake.nix` injects own inputs + upstream homeModules.
- All 5 nodes' eval is now blocked on **one class of error**:
  undefined `pkgs.vimPlugins.dwm-vim` (and likely sibling refs) in
  [CriomOS-home/modules/home/neovim/neovim/default.nix](repos/CriomOS-home/modules/home/neovim/neovim/default.nix)
  (346 lines). The neovim module is now imported unconditionally for
  every user on every node by the home aggregate.
- P0 lojix items (`lojix-auy` streaming, `lojix-cv1` atomic
  materialization) still open with band-aid `None` timeout in place.
- Open beads: 7 (`6u6` P1, `1ey` P2 epic, `bb5` P2, `og4` P3, `pzv`
  P3, `4xw` P3, plus lojix's own bucket).

## Five angles

### 1. Pragmatic — shortest path to green

Do `CriomOS-6u6` next: bisect or mass-trim the neovim plugin list
until eval is green on all 5 nodes, then close `home-tcj`.

- Pros: clears the visible blocker. Closes the longest-running P1.
  Single-file change, well-scoped.
- Cons: spends hours on a module that may not even matter (see §4).
  Gets us to "green eval" but not to "first deploy that exercises the
  newly-wired aggregate."

### 2. Strategic — unblock deploys, not eval

Address `lojix-auy` + `lojix-cv1` (both P0). Without streaming output,
deploys are silent multi-hour boxes; without atomic materialization,
crashes mid-deploy can corrupt artifacts. The vim issue is cosmetic
debt; these are the things that bite during a real `lojix deploy`.

- Pros: highest blast-radius items. P0 for a reason.
- Cons: requires a code-level read of lojix actor state machines, not
  a config-file trim. Bigger per-step than vim cleanup.

### 3. Architectural — extract `criomos-shared` (CriomOS-pzv)

Now that two repos provably consume the same `criomos-lib` and the
flake-level wrapper revealed where the seams are, extract it.

- Pros: prevents future divergence; removes the duplicate
  `specialArgs` constructor in both consumers; trivially testable.
- Cons: P3 for a reason — there is no forcing function. Doing this
  ahead of P0/P1 inverts the priority.

### 4. Skeptical — does the neovim module deserve a cleanup pass at all?

This is the angle that values the author's stated philosophy rather
than the inertia of the current tree.

The author's central themes (recovered from memory, AGENTS.md, and
recent reports 0013/0016/0017):

- **"What is installed is what is wanted."** Closure shrinkage was
  closed in 0016 on exactly this principle.
- **Lean schemas, no per-user opt-in fields.** 0016 rejected
  `preferredEditor`, `wantsAiAgents`, `languageFocus`, etc. on
  precisely this ground.
- **Intent-level naming, intent-level gating.** `wantsHwVideoAccel`,
  `behavesAs.largeAi`. Things should be on if and only if they're
  wanted.
- **No half-finished implementations.** Don't carry years of
  accumulation just because removal is more thinking than retention.
- **Forward-looking rules.** Don't keep a thing because today's tree
  uses it; ask whether tomorrow's intent uses it.

Applied honestly to the neovim module:

- VSCodium is the documented primary editor (extension packaging
  memory, vscodium module is the one that gets active maintenance).
- The emacs split (`emacs-plb` blocked on mkEmacs → blueprint) is the
  next-editor target.
- Neovim has been imported as `aolPloginz = pkgs.vimPlugins` with
  `dwm-vim` and lots of historical Lua, kept alive by neglect.
- The home aggregate currently imports `./neovim/neovim` for every
  user on every node, unconditionally.

The honest question is **not** "which plugins do we keep?" — it is
"do we want neovim at all?" If the answer is "rarely, on terminal-
only nodes," the right action is the lean-schema move:

1. Add a single `wantsNeovim` flag (default `false`) on the per-user
   horizon block, mirroring `wantsPrinting` precedent.
2. Make `./neovim/neovim` import conditional on it in the home
   aggregate.
3. Stop carrying 346 lines of broken plugin refs through every
   eval/build of every node.
4. If/when a node actually needs vim, opt in and trim the plugin list
   *for that intent*.

This ducks `CriomOS-6u6` entirely — the broken refs stop mattering
the moment the module isn't unconditionally imported. The closure
shrinks. The schema gains exactly one boolean. The principle holds.

What this angle is **not**: "delete neovim." It is "stop making
neovim the universal default of a system whose universal default is
VSCodium." Forward-looking.

### 5. Risk-reduction — verify before doing any of the above

Before committing to any direction, do the cheap reads that change
the question:

- `lojix-auy` / `lojix-cv1`: read the current actor code. If the band-
  aid `None` timeout + existing rename-on-write pattern actually
  cover the failure modes, downgrade or close. Cost: 30 min reading.
- `gold-vja`: confirmed closed last session.
- `home-f68` ("verify partially-done verbatim adaptation"): walk the
  diff vs upstream verbatim copies to confirm the cleanup that
  already happened is consistent. Cost: 30 min.

These three reads might collapse the open-beads queue from 7 → 4
without writing a line of new code.

## Recommendation

**Combine §4 + §5, in that order.**

1. (§5, ~30 min) Read lojix actor state for `auy`/`cv1`. Either
   downgrade them to P1 with concrete next-step notes, or surface
   what's actually missing.
2. (§4, ~1 hour) Add `wantsNeovim` (default `false`) to the per-user
   horizon block. Conditionally import neovim in the CriomOS-home
   aggregate. Re-run eval on the 5 nodes — should be green without
   touching a single plugin.
3. (defer) `CriomOS-6u6` becomes "trim the neovim plugin list when a
   user opts in," and stops being a P1 blocker — it's now P3 lazy work
   only paid for when actually needed. Update or close the bead.
4. Close `home-tcj` once eval is green via path 2.
5. Then revisit §1/§2/§3 with a cleaner queue.

The skeptical angle is the recommendation because it is the one that
matches the author's stated philosophy: don't grind on accumulated
debt that exists only because nothing was gating it. Gate it
correctly, and the debt evaluates to zero.

## What would invalidate the recommendation

- Author actually uses neovim on multiple nodes daily → §1 (do the
  cleanup) becomes correct.
- Author wants neovim as the universal terminal-fallback editor on
  *every* node regardless of GUI → §1 wins on the same logic.
- A pending P0 deploy is queued → §2 jumps the queue regardless.

Otherwise: §4 + §5.
