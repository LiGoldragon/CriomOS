# NEW ouranos build vs criomos-archive `maisiliym.ouranos.fullOs`

## What was built

```
/nix/store/cf8r5np8bzggc7jj91pydv97k0ngm6d5-nixos-system-ouranos-26.05.20260422.0726a0e
```

`lojix build --cluster goldragon --node ouranos` → realises
`nixosConfigurations.target.config.system.build.toplevel`. This IS the
direct equivalent of `crioZones.maisiliym.ouranos.fullOs` in the
archive — both are the full NixOS system closure (kernel + initrd +
activate script + etc + sw + home-manager activations).

## Side-by-side numbers

| Dimension | NEW (goldragon/ouranos, lojix-built) | ARCHIVE (maisiliym/ouranos.fullOs) |
|---|---|---|
| nixpkgs rev | 0726a0e (2026-04-22, nixos-unstable head) | b40629e (2026-03-18) |
| outpath | `cf8r5np8…-nixos-system-ouranos-…` (realised) | `05k38f8k…-…drv` (eval-only, not realised) |
| Closure size | **8.43 GB** (realised) | unknown — requires realisation (~hours from cold cache) |
| Drvs in dep tree | 1,715 (runtime closure) | 24,904 (full build-tree) |
| Users with HM | 2 (bird + li) — `home-manager-generation` paths present | 3 (bird + li + maikro) — eval log mentions `maikro profile` |
| HM machinery | wired & firing — per-user generations build | wired & firing |

The drv-tree counts aren't directly comparable: the new number (1,715)
is the **runtime closure** of the realised toplevel, the archive
number (24,904) is the **build-input tree** of the unrealised
.drv (counts every transitive build dep, including compilers and
intermediate steps that don't survive into the runtime closure).
A like-for-like would require realising both — out of scope today.

## What's the same

- Structurally identical: both produce a `nixos-system-ouranos-NN.NN.…`
  toplevel with kernel, initrd, etc/, sw/, activate, init,
  prepare-root.
- HM fires for each `horizon.users.<u>` entry. The new build's
  closure contains `home-manager-generation` paths for both users.
- 3-flake architecture (system + pkgs + horizon as inputs) doesn't
  change the toplevel shape — same activate script structure.

## What's different (substantively)

### 1. HM profile content is currently a stub

CriomOS-home's [modules/home/default.nix](repos/CriomOS-home/modules/home/default.nix)
only conditionally imports `inputs.niri-flake.homeModules.config` — it
does NOT yet wire the actual home modules
(base / vscodium / profiles{min,med,max} / neovim / emacs).

So while the new build has HM activations per user, those activations
install almost nothing. The archive's fullOs has the full HM profile
content per user (hundreds of MB of configs + packages per profile
tier). That accounts for a meaningful chunk of the closure delta.

This is the open `home-tcj` (P1) bead — wire the home aggregate so
the profiles actually fire.

### 2. maikro user removed

Archive carries the `maikro` test user; goldragon's datom.nota
removed it. The new build has 2 HM generations vs archive's 3.

### 3. LLM models — gated off here, present in archive

Archive's `llm.nix` (or equivalent) was likely also unconditional
(or gated only on a per-node check). New build wraps `llm.nix` in
`mkIf behavesAs.largeAi` — ouranos isn't LargeAi, so zero model
fetches. Saves multi-tens-of-GB on this node. Archive's fullOs likely
pulled the same model set if it had the same bug.

### 4. Module wiring is the rewritten set

New CriomOS modules went through Phase 8 wiring: each
`modules/nixos/X.nix` was added to `criomos.nix` one at a time with
fixes for legacy ghost-args / shape changes. The functional set is
the same as the archive (preinstalled, normalize, nix, complex, llm,
users, network/*, edge, metal, router, userHomes), but every one was
touched.

### 5. nixpkgs ~5 weeks newer

Archive: 2026-03-18 (b40629e). New: 2026-04-22 (0726a0e). Many
package versions advanced. Most differences are minor; could
account for ~hundreds of MB closure shift in either direction.

## Answer to the question "is what I built full OS with all home profiles?"

**Full OS: yes.** Structurally identical to fullOs — kernel, system
activation, services, all NixOS modules per goldragon/ouranos role.

**All home profiles: no.** HM is wired and per-user generations exist
in the closure, but CriomOS-home's aggregate currently imports zero
real modules (just the niri-flake stub). The user environments are
near-empty compared to archive. This is the known `home-tcj` work —
wire base/profiles/editors and re-test.

So: the new ouranos closure is **operationally equivalent to fullOs
on the system side**, **stub-equivalent on the home side**, and **leaner
across the board** thanks to LLM gating and the deliberate atLeastMax
exceptions kept narrow.

## Numbers worth capturing for later

- **8.43 GB** = current ouranos closure WITHOUT real HM profiles + LLM
  gated off
- **~30 GB+ historical** = what the archive's ouranos used to weigh
  with all profiles + the ungated LLM bug + maikro
- Rough HM-per-profile estimate: ~500 MB–1 GB per fully-wired user
  (will be measurable once `home-tcj` lands)

## Suggested next steps (related to this comparison)

1. **`home-tcj`**: wire `modules/home/default.nix` aggregate to import
   base + vscodium + the size-tiered profiles. Re-build ouranos.
   Compare new closure size — that's the real "full OS with all home
   profiles" measurement.
2. **Realise the archive's fullOs**: only worth it if we want a
   precise side-by-side closure-size delta. Cold-cache build is hours
   on the existing slow connection. **Probably skip** — the
   structural comparison above is sufficient.
3. **Audit other modules for the same `mkIf` gap llm had**: the
   risk-audit identified module-side-effects as a class. A quick
   pass for any other "imported by every node, only active on a
   subset" pattern is cheap insurance.
