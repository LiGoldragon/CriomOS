# 2026-04-24 — rewrite status snapshot (end of session)

State of the CriomOS / CriomOS-home / lojix / horizon-rs / goldragon
ecosystem at the moment context compact was requested. Read this
to cold-open the project.

## TL;DR

- **3-flake architecture** (system + pkgs + horizon as content-addressed
  flake inputs) is **shipped and verified**. lojix produces all 3
  inputs; CriomOS consumes them. See [2026-04-24-3flake-implemented.md](2026-04-24-3flake-implemented.md).
- **horizon-rs schema** is operationally complete. Recent refactor:
  `Mg` struct (Magnitude + AtLeast bundled). See [2026-04-24-mg-refactor.md](2026-04-24-mg-refactor.md).
- **CriomOS module rewrite** is mostly done:
  - `world` / `pkdjz` / `hob` ghost args **gone** from active code
    (only `emacs/emacs/default.nix` in CriomOS-home retains
    `pkdjz.mkEmacs`, blocked on criomos-emacs split).
  - All `.methods.X` flattened to flat fields (or `Mg.is.X` for
    magnitude predicates).
  - `zones/` and `sphere/` deleted — superseded by horizon-rs.
- **Phase 8 (wire criomos.nix imports)** is **partially done**.
  `disks/preinstalled.nix`, `normalize.nix`, `nix.nix`, `complex.nix`,
  `llm.nix`, `users.nix` are wired and all 6 goldragon nodes still
  produce real toplevel drvPaths. Remaining: `network/*`, `metal/`,
  `edge/`, `router/*`, `disks/{liveiso,pod}`, `userHomes.nix`.
- **lojix** is functional for `eval` end-to-end. Not yet hardened:
  see open beads.

## What's wired in `criomos.nix` today

```
imports = [
  ./disks/preinstalled.nix
  ./normalize.nix
  ./nix.nix
  ./complex.nix
  ./llm.nix
  ./users.nix
];
```

Each was added incrementally with a `lojix eval` regression check
on all 6 goldragon nodes. The wire-and-test pattern: add one
import, run `lojix eval` against ouranos, fix any issue (typically
a stale path or a mismatched horizon field name), then test all 6.

## What's NOT wired yet

In `modules/nixos/` but not yet imported by `criomos.nix`:

- `network/{default, unbound, yggdrasil, headscale, tailscale, networkd, nordvpn, wifi-eap, trust-dns, wireguard}.nix`
  — bring in via `./network` (which imports the rest)
- `metal/default.nix` — heavy, hardware-specific (ThinkPad firmware,
  GPU, suspend, libvirtd, waydroid, etc.)
- `edge/default.nix` — desktop environment (niri/GNOME/etc.)
- `router/{default, wifi-pki, yggdrasil}.nix` — for router-class
  nodes (prometheus is largeAI-router)
- `disks/{liveiso, pod}.nix` — alternate disk layouts (ISO,
  containers)
- `userHomes.nix` — depends on CriomOS-home homeModules.default
  being non-empty (which is partially true now: it imports
  niri-flake.homeModules.config conditionally)

The right next step is to add `./network` to `criomos.nix` imports
and iterate on whatever errors emerge. Each module is mechanically
clean post-refactor; failures will mostly be horizon-field-name
mismatches (e.g. another `cacheURLs` → `cacheUrls` style fix) or
stale relative paths to packages.

## CriomOS-home state

`modules/home/default.nix` aggregate currently imports
`inputs.niri-flake.homeModules.config` conditionally. Doesn't yet
import the actual home modules (base, vscodium, profiles, neovim,
emacs).

The home modules have all been ghost-arg-cleaned and flattened.
`emacs/emacs/default.nix` is the only one with remaining legacy
(`pkdjz.mkEmacs`) — blocked on criomos-emacs split.

To wire CriomOS-home properly, a similar wire-and-test loop is
needed inside `modules/home/default.nix` — each home module added
and tested. The blocker is: home-manager evaluation isn't currently
exercised end-to-end by `lojix eval` (the toplevel.drvPath path
doesn't trigger home-manager). Need a separate test harness.

Tracked as `home-tcj` (P1).

## lojix state

Single-shot eval pipeline works. Cache property holds across runs
and machines (via narHash). Three big gaps tracked:

- `lojix-auy` P0 — stream subprocess stdout/stderr (currently
  buffered)
- `lojix-cv1` P0 — atomic artifact materialization
- `lojix-d56` P1 — tarball publish to a remote target (still local-only)

Plus 7 other open beads (root check, error tests, all-actions
tests, --target-host plumbing, etc.).

## Beads — open critical-path items

Across repos, the path-to-real-deploy:

1. **CriomOS-gqq** P1 — wire remaining `criomos.nix` imports
   (Phase 8). Mechanical, ~1–2 hours of fix-and-test.
2. **lojix-auy** P0 — stream subprocess output (avoid silent hangs).
3. **lojix-cv1** P0 — atomic materialization (crash safety).
4. **lojix-eop** P1 — root check for Switch/Boot/Test.
5. **CriomOS-1ey** P2 — audit fixes from old AUDIT-2026-04-17.md.
6. **emacs-plb** (CriomOS-emacs, blocked) — convert mkEmacs to
   blueprint package; unblocks `home-tl6` (CriomOS-home wire
   criomos-emacs input) which unblocks the last remaining ghost-arg
   in CriomOS-home (`emacs/emacs/default.nix`'s `pkdjz.mkEmacs`).

## Open questions / decisions pending

1. **`Mg.is` vs `Mg.atLeast` naming** — see
   [2026-04-24-mg-refactor.md](2026-04-24-mg-refactor.md). Filed
   as a bead.
2. **CriomOS-home aggregate wiring** (Phase A in the home rewrite
   track) — when to start? Could be done in parallel with CriomOS
   Phase 8 module wiring.
3. **criomos-emacs scaffold timing** — affects when the last
   ghost-arg in CriomOS-home gets removed.
4. **`size.is.X` vs `size.atLeast.X` naming** — same as Q1 above.
5. **`nix.nix` flake-registry entries** — currently registers
   nixpkgs, home-manager, brightness-ctl, criomos-home. Should it
   also register clavifaber, blueprint, rust-overlay, the new
   `system`/`pkgs`/`horizon` inputs? (Probably not the latter
   three — they're orchestrator-controlled, not end-user-relevant.)

## Reports map

Other reports in this dir (in chronological order):

- `2026-04-24-ecosystem-audit.md` — first ecosystem-wide audit.
- `2026-04-24-ractor-tool-design.md` — lojix actor architecture
  design (with cache-property analysis).
- `2026-04-24-3flake-implemented.md` — system + pkgs + horizon
  3-flake architecture, implemented.
- `2026-04-24-nix-rewrite-and-pkgs-input.md` — superseded by
  3flake-implemented (kept for history; §4 had wrong initial
  pkgs-as-flake-input interpretation).
- `2026-04-24-architecture-deep-audit.md` — 4-agent forensic
  audit; basis for the bead set being worked through now.
- `2026-04-24-world-hob-removal.md` — canonical replacement plan
  for the legacy ghost-arg layer; mostly executed.
- `2026-04-24-mg-refactor.md` — the Mg struct refactor.
- This file (`2026-04-24-rewrite-status.md`) — end-of-session
  snapshot.

## How to resume

To pick this up after compact:

1. `bd list --status open` in CriomOS, lojix, CriomOS-home,
   horizon-rs, goldragon, CriomOS-emacs, clavifaber,
   brightness-ctl. The critical-path items are listed above.
2. `cd /home/li/git/lojix && cargo build --release -p horizon-cli`
   to rebuild the orchestrator if changes happened upstream.
3. `lojix eval --cluster goldragon --node ouranos --source
   /home/li/git/goldragon/datom.nota --criomos
   path:/home/li/git/CriomOS` is the canonical regression test.
   Should produce a real toplevel.drvPath in stdout.
4. Phase 8 next step: add `./network` to `criomos.nix` imports
   and iterate. The pattern is in `2026-04-24-rewrite-status.md`
   §"What's wired in criomos.nix today".
