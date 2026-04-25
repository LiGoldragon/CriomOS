# Trim + extract — outcome

User directive (post-0021): "trim neovim to bare minimum, drop emacs
if needed, extract a CriomOS-lib repo, trim all the problematic stuff
and we'll build it back up later if we need it."

## What landed

### Editors
- **neovim**: 346-line module → 7-line stub
  ([CriomOS-home/modules/home/neovim/neovim/default.nix](repos/CriomOS-home/modules/home/neovim/neovim/default.nix)).
  All sidecar `.lua` and `leftovers.vim` deleted. Plugins, LSP, Lua
  modules, treesitter wiring, colemak/dwm layers — gone. Bare-min
  retains `programs.neovim.enable = true; vimAlias = true;` plus
  `EDITOR = "nvim"`.
- **emacs**: entire `modules/home/emacs/` subtree deleted. Was blocked
  on `pkdjz.mkEmacs` (memory `feedback_pkdjz_discouraged.md`). Will
  return via `criomos-emacs` flake (bead `emacs-plb`).
- Aggregate import line for `./emacs/emacs` removed from
  [modules/home/default.nix](repos/CriomOS-home/modules/home/default.nix).

### CriomOS-lib repo
New flake at `github:LiGoldragon/CriomOS-lib` (rev `68cd5445`, public).
Contents:
- `lib/default.nix` — `importJSON`, `mkJsonMerge`. Surface
  `inputs.criomos-lib.lib`.
- `data/largeAI/llm.json` — moved from `CriomOS/data/config/largeAI/`.
  Surface `inputs.criomos-lib + "/data/largeAI/llm.json"`.
- `AGENTS.md` / `CLAUDE.md` shim per ecosystem convention.
- No nixpkgs dependency — stays cheap to evaluate.

### Wiring
- **CriomOS** [flake.nix](flake.nix) now declares `criomos-lib` as
  input; `criomos-home` declares `criomos-home.inputs.criomos-lib.follows
  = "criomos-lib"` so one rev pins across the system. Local
  `import ./lib { }` → `inputs.criomos-lib.lib`. `lib/` directory
  deleted (with the legacy file).
- **CriomOS-home** [flake.nix](repos/CriomOS-home/flake.nix) wrapper
  now also injects `_module.args.criomos-lib = lib.mkForce
  inputs.criomos-lib.lib` alongside the existing `_module.args.inputs`
  fix. Empty `lib/` placeholder deleted.
- **CriomOS** [llm.nix](modules/nixos/llm.nix) takes `inputs` arg and
  reads `configPath = inputs.criomos-lib + "/data/largeAI/llm.json"`.

### Incidental bit-rot trimmed (collateral, not part of the directive)
Eval surfaced three pre-existing issues that had to be cleared so the
green-eval state could be observed:

- `nodePackages` (removed from current nixpkgs) — dropped the unused
  `tokenaizdWrangler` binding plus the
  `++ (with nodePackages; [stylelint postcss prettier])` tail of
  `codingPackages` in
  [profiles/med](repos/CriomOS-home/modules/home/profiles/med/default.nix).
- Doubled `modules/home/nonNix/nonNix/` nesting → flattened to
  `modules/home/nonNix/`.
- `profiles/min`'s `../nonNix/zshrc` resolved to
  `modules/home/profiles/nonNix/zshrc` (which never existed); fixed to
  `../../nonNix/zshrc`.

### Beads closed
- `home-tcj` (P1) — aggregate is wired and eval-green.
- `CriomOS-6u6` (P1) — vim-plugin cleanup obviated by trim.
- `CriomOS-pzv` (P3) — criomos-shared / CriomOS-lib extraction landed.

## Eval state — 5 nodes

| Node | State |
|---|---|
| ouranos | **green** (drvPath emitted) |
| tiger | **green** (drvPath emitted) |
| zeus | **green** (drvPath emitted) |
| balboa | green at module level; needs aarch64 builder for full eval |
| prometheus | green at module level; LLM FOD store path needs realisation |

Both balboa and prometheus blockers are environmental, not code.

## Eval-cache gotcha (operator note)

`nix flake update <input> --refresh` in the local CriomOS flake updates
the local lock — but `lojix eval` invokes `nix eval
github:LiGoldragon/CriomOS#…` which uses the **github** flake's lock at
HEAD. After pushing a new CriomOS-home commit + bumping CriomOS's lock
+ pushing CriomOS, the next `lojix eval` may still serve the cached
prior source tree. Force a fresh fetch with:

```
nix flake metadata github:LiGoldragon/CriomOS-home --refresh
```

before re-running `lojix eval`. Worth wiring `--refresh` into lojix's
`nix eval` invocation eventually (own bead candidate).

## Open beads after this session

- `CriomOS-1ey` (P2 epic) — criomos-archive AUDIT-2026-04-17 fixes.
- `CriomOS-bb5` (P2) — criomos-cfg side-repo (proper 3-way merge).
- `CriomOS-4xw` (P3) — criomos-hw-scan CLI.
- `CriomOS-og4` (P3) — ROADMAP.md fate decision.
- `home-f68` (P1) — verify verbatim adapt for new horizon schema.
- `home-tl6` (P2) — wire criomos-emacs (blocked on `emacs-plb`).
- `lojix-auy` / `lojix-cv1` / `lojix-d56` — P0/P1 streaming +
  materialization + tarball publish.
- `gold-8gn` / `gold-a1u` — yggdrasil pubkey + per-user explicit style.
- `bright-2iz` / `clavi-37x` / `clavi-5a5` — Mentci restyle / Cargo
  audit.

## Repo state (post-session)

| Repo | What changed |
|---|---|
| **CriomOS** | criomos-lib added as flake input + criomos-home follows; `import ./lib { }` → `inputs.criomos-lib.lib`; `llm.nix` takes `inputs`, reads from `inputs.criomos-lib`; `lib/` and `data/config/largeAI/` deleted; empty `data/config/pi/` removed; reports 0021 + 0022. |
| **CriomOS-home** | bare-min neovim (346 → 7 lines, sidecars deleted); emacs subtree deleted; `criomos-lib` flake input added + injected via wrapper; `lib/` placeholder deleted; profiles/med nodePackages refs trimmed; nonNix flattened + relpath corrected. |
| **CriomOS-lib** | NEW. Initial commit with `flake.nix` + `lib/default.nix` + `data/largeAI/llm.json` + AGENTS.md + CLAUDE.md shim + README.md. Public repo on github. |
| lojix / horizon-rs / goldragon | Untouched. |
