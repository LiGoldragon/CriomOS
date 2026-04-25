# Agent Bootstrap — CriomOS

## Tool references

Cross-project rules and curated tool docs live in
[`repos/tools-documentation/`](repos/tools-documentation/) (symlinked to
`~/git/tools-documentation/`). Start there for: jj workflow + always-push
rule, Rust style, the canonical crane+fenix Nix packaging layout, and
basic-usage docs for jj / bd / dolt / nix.

## First thing

Run `bd list --status open` to see what's already on the table.

Read `docs/ROADMAP.md` for porting order and open tasks.

## Hard architectural rules

- **Network-neutral.** CriomOS does NOT know the names of clusters or
  nodes. Any input with a `NodeProposal` attr is a cluster; every node
  in that proposal gets `crioZones.<cluster>.<node>.*`. Never introduce
  `hosts/<name>/` or any filesystem-keyed enumeration of live networks.
- **Home lives in `CriomOS-home`.** Do not add `modules/home/` here.
  Consume home via `inputs.criomos-home.homeModules.*`.
- **Horizon is external.** Schema + method logic live in `horizon-rs`
  (Rust). Nix only consumes the enriched horizon as nota (camelCase fields).
- **No Rust crates in this repo.** Rust crates live in their own repos
  (e.g. `clavifaber`, `brightness-ctl`, `horizon-rs`) and are consumed
  as flake inputs. Never inline a Rust crate under `packages/`.

## Hard process rules

- Jujutsu only. Never `git` CLI.
- Push before building; build from origin with `--refresh`.
- Never put Nix store paths in conversation context — capture in shell vars.
- Never use `<nixpkgs>` / `NIX_PATH`; use flake attrs or `nix shell nixpkgs#jq`.
- Never run `switch-to-configuration switch` in a chroot.
- Never live-activate home-manager generations with compositor/input changes.
- Never SIGHUP niri.
- SSH keys only — no password auth, ever.

## AGENTS.md / CLAUDE.md convention

`AGENTS.md` is the single source of truth; `CLAUDE.md` is a one-line
shim reading `See [AGENTS.md](AGENTS.md).`. This way Codex (which reads
`AGENTS.md`) and Claude Code (which reads `CLAUDE.md`) converge. Don't
duplicate content into `CLAUDE.md`. When creating new repos under this
ecosystem, copy the same shim.

## Documentation layers — strict separation

| Where | What | Example |
|---|---|---|
| `docs/*.md` | **Prose / contracts only.** No long code blocks. Architectural rules, guidelines, roadmap, invariants. | `docs/GUIDELINES.md`, `docs/ROADMAP.md` |
| `reports/NNNN-MM-DD-*.md` | **Concrete shapes + decision records.** Type sketches, audit findings, research syntheses, design proposals, migration journeys, end-of-session snapshots. | `reports/2026-04-25-closure-bloat-audit.md` |
| the modules themselves | **Implementation.** Nix code, packages, tests. | `modules/nixos/normalize.nix` |

If a layer rule is violated, rewrite: move type sketches out of `docs/`
into a report; move runnable code out of reports into the appropriate
module. Architecture stays slim so it remains readable in one pass.

**Delete wrong reports — don't banner them.** Superseded reports get
deleted, not wrapped in a "this is wrong now" banner. The git history
keeps the trace; the live reports/ dir reflects current truth.

## Session-response style — substance goes in reports

If your final-session response would be more than minimal (a few lines),
write the substance as a report (in `reports/`) and keep the chat reply
minimal — a one-line pointer at the report. Two reasons: (1) the Claude
Code UI is a poor reading interface, files are easier; (2) the author
reviews responses asynchronously while the agent moves to next work, so
the substance must be in a stable, scrollable, file-backed place.

Small reports are fine — the report doesn't have to be large.
Acknowledgements, tool-result summaries, "done; pushed" confirmations
don't need reports. Anything that explains, proposes, analyses, or
summarises does.

## bd vs files

`bd` (beads) tracks short items: open issues, tasks, workflow state. One
line per item. Designs, audits, research syntheses, end-of-session
snapshots go in `reports/` as files. See
[bd/basic-usage.md §"bd vs files"](repos/tools-documentation/bd/basic-usage.md#bd-vs-files--when-each-is-the-right-home)
for the long version.

`bd prime` auto-runs at session start (`PreCompact` and `SessionStart`
hooks in `.claude/settings.json`) and gives current state.

## Blueprint specifics

- Per-system files (`packages/*`, `devshell.nix`, `checks/*`) receive
  `{ pkgs, inputs, flake, system, perSystem, pname, ... }`.
- `modules/nixos/<name>.nix` surfaces as `nixosModules.<name>` and
  `modules.nixos.<name>`.
- `lib/default.nix` surfaces as `lib`.
- Custom outputs (like `crioZones`) are merged into blueprint's return
  value in `flake.nix`.
