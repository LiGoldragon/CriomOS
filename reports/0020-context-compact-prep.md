# Context-compact prep — session close-out

Consolidates this session's work + flags loose ends + cross-repo
shared-concerns + housekeeping deletions. Numbered as the next report
post-`0019` (incremental rule per AGENTS.md).

## What landed this session

### CriomOS-home — flake-level inputs injection (the architecture fix)

- `flake.nix` outputs now wrap `homeModules.default` to:
  - import upstream `homeModules.{stylix, niri-flake, noctalia}` so
    their option paths exist in the module-set
  - override `_module.args.inputs` to CriomOS-home's own flake inputs
- `modules/home/default.nix` re-enables active imports of base +
  profiles + editors (the niri-flake conditional is no longer needed —
  the wrapper imports it).
- CriomOS `userHomes.nix` drops `inputs` from `extraSpecialArgs`
  (it was shadowing the wrapper's value via specialArgs precedence).
- `pi-mentci` dropped entirely from CriomOS-home's flake.nix +
  modules + flake.lock.
- All `aski`-related code dropped (vscode-aski extension already gone;
  also dropped the `~/.local/share/mime/packages/aski.xml` MIME def
  and the `text/x-aski` xdg.mimeApps entry).
- `home.stateVersion` removed from `base.nix` (consumer
  userHomes.nix is the authoritative source — sets `26.05`).

### Other cleanups in same session
- llm.nix gated `mkIf behavesAs.largeAi` (only prometheus runs LLMs).
- Killed the overnight build that was downloading multi-GB GLM
  models on ouranos (84 GB freed from /nix/store).
- Reports renumbered from `YYYY-MM-DD-name.md` to `NNNN-name.md`
  per Li's "incremental, no date" rule.

## Loose end — broken vim-plugin refs

Wire-up eval blocked on `dwm-vim` (and likely many more) being
undefined in `pkgs.vimPlugins`. The neovim module
([modules/home/neovim/neovim/default.nix](repos/CriomOS-home/modules/home/neovim/neovim/default.nix))
references many plugins that have been renamed or removed from
nixpkgs over the years.

**Path forward** (needs Li's input): bisect plugin-by-plugin OR
mass-trim to minimal known-good set + add back what's actively
used. Either way, this is a separate cleanup pass.

## Reports housekeeping

Per AGENTS.md "delete wrong reports — don't banner them":

- **Deleted**: [reports/0001-ecosystem-audit.md](reports/) (superseded by 0009).
- **Deleted**: [reports/0003-nix-rewrite-and-pkgs-input.md](reports/) (superseded by 0004; its own header noted "wrong initial pkgs-as-flake-input interpretation").
- **Reports/ now: 0002, 0004–0019, plus this 0020.** Gaps from deletes are kept (numbers don't get reused).

Post-deletion next number = 0021.

## Stale docs flagged for next pass

- [docs/ROADMAP.md](docs/ROADMAP.md) — still lists Phase 1–5 items as
  open but Phase 8 is closed (`CriomOS-gqq`). Either rewrite around
  current state or delete entirely (beads are now the authoritative
  roadmap; AGENTS.md should clarify if so).
- [CriomOS-home/docs/ROADMAP.md](repos/CriomOS-home/docs/ROADMAP.md)
  — same drift; references modules as "verbatim copies" but they've
  been ghost-arg-cleaned + flattened.
- `criomos-archive/capnp/*` — concept-only, no live consumer.
  Candidate for delete.

## Beads — open list (post-session)

| ID | P | What | Status |
|----|---|------|--------|
| `CriomOS-1ey` | P2 | Audit fixes from criomos-archive AUDIT-2026-04-17 | open, valid |
| `CriomOS-bb5` | P2 | criomos-cfg side-repo (3-way merge + drift) | open, deferred |
| `CriomOS-4xw` | P3 | criomos-hw-scan CLI | open, designed |
| `home-tcj` | P1 | CriomOS-home aggregate wiring | **architecture fixed; final eval blocked on broken vim-plugin refs** |
| `home-f68` | P1 | Adapt verbatim home modules to new horizon shape | open — partially done; verify |
| `home-tl6` | P2 | Wire criomos-emacs as input | blocked on emacs-plb |
| `lojix-auy` | P0 | Stream subprocess output | open — band-aid `None` timeout in place; real streaming pending |
| `lojix-cv1` | P0 | Atomic artifact materialization | open — needs code-level audit |
| `lojix-d56` | P1 | Tarball publish for cross-machine deploys | open |
| `gold-8gn` | P3 | Yggdrasil pubkey for prometheus | open, valid |
| `gold-vja` | P3 | Asklepios + eibetik fate (now both removed) | **stale — close** |
| `gold-a1u` | P4 | Explicit Style per user | open, valid |
| `emacs-plb` | (blocked) | mkEmacs → blueprint package | blocked, pre-condition for `home-tl6` |
| `bright-2iz`, `clavi-37x`, `clavi-5a5` | P3-4 | Mentci restyle / Cargo audit on Rust crates | open, valid |

## Cross-repo shared-concern marker

Per Li's "mark cross-repo stuff to be put into a shared repo (for OS
and home)":

### Genuine shared candidates (should live in a `criomos-shared` repo)
1. **`criomos-lib`** — currently in
   [/home/li/git/CriomOS/lib/default.nix](lib/default.nix), exporting
   `importJSON` + `mkJsonMerge`. CriomOS-home consumes both
   ([profiles/min:53](repos/CriomOS-home/modules/home/profiles/min/default.nix#L53),
   [vscodium/vscodium:11](repos/CriomOS-home/modules/home/vscodium/vscodium/default.nix#L11)).
   Currently both repos pass `criomos-lib` as a special arg they each
   set up independently. **Extract**: tiny new flake `criomos-shared`
   with a `lib.default` output, both repos pull as input.

2. **Data files referenced cross-repo**:
   - `data/config/largeAI/llm.json` — currently in CriomOS, would be
     useful if CriomOS-home wanted to know which model to point a
     client at (the stubbed largeAI block we dropped). If the client-
     side largeAI helper is ever revived, the config has to be visible
     to both. Move to `criomos-shared/data/` if/when that revival
     happens. **Today: leave in CriomOS.**
   - `data/ZedKeymaps/goldragon-colemak.json` — referenced by
     CriomOS-home but doesn't exist anywhere. **Either**: someone
     creates it (in `criomos-shared/`), or the Zed colemak feature
     stays stubbed. Today: stubbed.

### Not actually shared (no extraction needed)
- horizon-rs schema — already its own repo.
- nota fixtures — single source of truth in goldragon's `datom.nota`.
- llm.nix — only CriomOS consumes; the data file is its only
  near-shared concern (covered above).

### Filed
- Beads candidate for the criomos-shared extraction: `CriomOS-shr`
  (P3, deferred — no urgent forcing function).

## Verification: post-architecture-fix eval state

`lojix eval --node ouranos` now passes through the inputs-injection
fix successfully. Eval errors out **after** the wrapper takes effect,
on a real broken-plugin reference (`dwm-vim`). Not a regression — it's
exposing a layer of debt that was hidden by the prior input-shadow
issue.

5 nodes (balboa / ouranos / prometheus / tiger / zeus) eval state:
all blocked on the same neovim plugin refs (since neovim is
unconditionally imported via the home aggregate now).

## Next concrete actions for the next session

1. **Vim-plugin cleanup** — Li to indicate which plugins to keep
   (or do a mass trim + per-feature add-back).
2. **Verify `lojix-auy` + `lojix-cv1`** — read the actual lojix code
   for current state, close if irrelevant.
3. **Close `gold-vja`** — asklepios + eibetik are gone from
   datom.nota.
4. **ROADMAP.md decision** — rewrite vs delete + AGENTS.md addendum.

## Status of touched repos this session

| Repo | What changed |
|------|--------------|
| **CriomOS** | userHomes.nix drops `inputs` from extraSpecialArgs; reports/ housekeeping (drop 0001+0003, add 0020). |
| **CriomOS-home** | flake.nix wrapper for homeModules.default; default.nix re-enables imports; pi-mentci + aski + dead refs dropped; base.nix stateVersion conflict resolved. |
| **horizon-rs / lojix / goldragon** | Untouched this turn (all stable post-prior session work). |
