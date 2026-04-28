# Agent Bootstrap — CriomOS

## Tool references

Cross-project rules and curated tool docs live in
[`repos/tools-documentation/`](repos/tools-documentation/) (symlinked to
`~/git/tools-documentation/`). Start there for: jj workflow + always-push
rule, Rust style, the canonical crane+fenix Nix packaging layout, and
basic-usage docs for jj / bd / dolt / nix / lojix-cli.

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
| `reports/NNNN-*.md` | **Concrete shapes + decision records.** Type sketches, audit findings, research syntheses, design proposals, migration journeys, end-of-session snapshots. Numbered incrementally — see below. | `reports/0013-closure-bloat-audit.md` |
| the modules themselves | **Implementation.** Nix code, packages, tests. | `modules/nixos/normalize.nix` |

If a layer rule is violated, rewrite: move type sketches out of `docs/`
into a report; move runnable code out of reports into the appropriate
module. Architecture stays slim so it remains readable in one pass.

**Reports are NOT durable documentation.** They are point-in-time
records — audits, decision records, migration journeys, session
snapshots, research syntheses. Durable architectural guidance —
"how this thing works", "why X is gated by Y", "the rule for Z",
"the design rationale behind A" — belongs in `docs/`, in the
relevant repo's `ARCHITECTURE.md`, in `AGENTS.md`, or in code
comments. When a report contains durable substance, *implement it*
(move to the right home) rather than leaving it in `reports/`.
This is the same principle as the rollover rule's "implement"
option — except it applies at write-time too, not just at rollover.

**Reports are numbered incrementally** — `0001-*.md`, `0002-*.md`, …
When adding a new report, take the next available integer (highest
existing number + 1) and zero-pad to four digits. No date in the
filename — there will be many reports per day. Date metadata, if
needed, goes in the report body, not the path.

**Delete wrong reports — don't banner them.** Superseded reports get
deleted, not wrapped in a "this is wrong now" banner. The git history
keeps the trace; the live reports/ dir reflects current truth.
Numbers don't get reused — gaps are fine.

## Report hygiene — don't restate-to-refute

When a frame has been **decisively rejected** (a bd memory, an
AGENTS.md rule, or a chat correction): do not re-present it as a
candidate in subsequent reports just to refute it. State only the
correct frame.

When a previous report's premise is **wrong**: delete it and write a
clean successor that states only the correct view. Do not append
corrections, do not banner, do not restate-to-refute.

Rejected frames are recorded once — in a bd memory or as an AGENTS.md
rule — and only as one-line entries. Forensic narratives ("here's how
this contamination crept in") are not reports — their lessons land in
bd memories as one-liners; the forensic narrative itself goes too.

## Report rollover at the soft cap

**Soft cap: ~12 active reports** in `reports/`. When the count
exceeds this, run a rollover pass before adding the next report. For
each existing report, decide one of:

1. **Roll into a new consolidated report.** Multiple reports covering
   the same evolving thread fold into a single forward-pointing
   successor. The successor supersedes the old reports; the old ones
   are deleted (no banner).

2. **Implement.** If the report's substance can be expressed as an
   `AGENTS.md` rule, as code (skeleton-as-design in the relevant
   module), or as a `docs/` contract, move it to the right home and
   delete the report.

3. **Delete.** If the report's content is already absorbed elsewhere
   or its premise has been refuted, delete it.

The choice is made by reading each report against the author's intent
— no mechanical rule. When unclear, ask Li.

The cap is **soft** in that it triggers a rollover pass, not an
instant rejection; it is **firm** in that the pass must run before the
next new report lands.

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

## Memory — agent-agnostic only

**Never write Claude-specific memories** (no `~/.claude/projects/.../memory/*.md`,
no `MEMORY.md` index file). Memory has two homes, both agent-agnostic:

- **Short rules / facts** — `bd remember "<one-liner>"`. Cross-session,
  searchable via `bd memories <keyword>`. Same store across Claude /
  Codex / any other agent that speaks bd.
- **Longer references** — `docs/` in the relevant repo, or `AGENTS.md`
  for cross-cutting agent conventions.

If a tool-specific memory dir exists from prior sessions, migrate its
content (descriptions → `bd remember`; bodies that are durable
references → `docs/`) and delete the dir.

## Blueprint specifics

- Per-system files (`packages/*`, `devshell.nix`, `checks/*`) receive
  `{ pkgs, inputs, flake, system, perSystem, pname, ... }`.
- `modules/nixos/<name>.nix` surfaces as `nixosModules.<name>` and
  `modules.nixos.<name>`.
- `lib/default.nix` surfaces as `lib`.
- Custom outputs (like `crioZones`) are merged into blueprint's return
  value in `flake.nix`.
