# Agent instructions — CriomOS

You **MUST** read AGENTS.md at `github:ligoldragon/lore` — the workspace contract. After devshell entry it's also symlinked locally at `repos/lore/AGENTS.md`.

## Repo role

NixOS-based host OS for the sema ecosystem. Network-neutral system surface (`nixosConfigurations.target`) consumed by lojix-projected `horizon` and `system` flake inputs.

This repo doubles as the **CriomOS-cluster meta-repo** — `repos/` symlinks the cluster siblings (CriomOS-home, CriomOS-emacs, horizon-rs, lojix-cli, …) and lore. `CriomOS.code-workspace` mirrors the same set for the editor.

First thing: run `bd list --status open`. Read `docs/ROADMAP.md` for the bead-first tracking rule.

## Hard architectural rules

- **Network-neutral.** CriomOS holds no cluster or node names. The single public system surface is `nixosConfigurations.target`. Cluster + node identity enter through the lojix-projected `horizon` and `system` flake inputs.
- **Home lives in `CriomOS-home`.** This repo consumes home via `inputs.criomos-home.homeModules.*`.
- **Horizon is external.** Schema + method logic live in `horizon-rs` (Rust). Nix consumes the enriched horizon as nota (camelCase fields).
- **Rust crates live in their own repos** (`clavifaber`, `brightness-ctl`, `horizon-rs`, …) and are consumed as flake inputs.
- **Every application enters as a Nix derivation** — packaged upstream in nixpkgs, in a flake input, or in this ecosystem's `packages/`. The stateful escape hatch is forbidden because it breaks reproducibility-from-the-flake-alone, which is the whole point of CriomOS. Applies even to "test" / "one tool" — testing happens in `nix shell` / `nix run`. The only acceptable mutation outside Nix is data the application owns at runtime (browser bookmarks, editor buffers, shell history) — never the application itself or its dependencies. For Python: `uv2nix` / `pyproject-nix` consuming a committed `uv.lock`.

## Hard process rules

- Push before building; build from origin with `--refresh`.
- Store paths live in shell variables, never in prose, code blocks, or commit messages. A `/nix/store/<hash>-<name>` literal in the chat log freezes a build artefact into the conversation forever; the hash drifts with every input bump and the next run reads stale context as if it were authoritative. Capture in `X=$(nix build … --print-out-paths --no-link)` and reference `$X`.
- For one-shot invocations of a nix-built tool, prefer `nix run <flake>#<attr> -- <args>`. Reach for `nix build` only when the store path itself is load-bearing (closure introspection, manual `nix copy`, etc.) — and even then capture it in a shell var.
- Use flake attrs or `nix shell nixpkgs#jq`, not `<nixpkgs>` / `NIX_PATH`.
- `switch-to-configuration switch` stays out of chroots.
- niri stays unsignalled (no SIGHUP).
- SSH keys only — no password auth.
- **Paid LLM API calls require explicit permission.** Cloud inference (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, any vendor key in `gopass`) costs the user real money per token. "Test it" / "try it" / "feel free to test" mean local-only testing. The order of operations for any task that needs an LLM endpoint: (1) use the local model hosted on prom; (2) if prom is unreachable or the model is unsuitable, ask the user before reaching for any paid key. This applies to every wrapper around inference too — `browser-use`, `aider`, `goose`, anything that calls out per step.

## Documentation layers — CriomOS-specific

| Where | What |
|---|---|
| `docs/*.md` | **Prose / contracts.** Architectural rules, guidelines, roadmap, invariants. |
| `reports/NNNN-*.md` | **Concrete shapes + decision records.** Type sketches, audit findings, research syntheses, design proposals, migration journeys, end-of-session snapshots. Numbered 4-digit, incrementally — take the next available integer; gaps are fine. No date in filename. |
| The modules themselves | **Implementation.** Nix code, packages, tests. |

Reports are point-in-time records; durable architectural guidance lives in `docs/`, `ARCHITECTURE.md`, `AGENTS.md`, or code comments. When a report contains durable substance, move it to the right home rather than leaving it in `reports/`.

## Memory — agent-agnostic only

Memory has two homes, both agent-agnostic:

- **Short rules / facts** — `bd remember "<one-liner>"`. Cross-session, searchable via `bd memories <keyword>`. Same store across Claude / Codex / any other agent that speaks bd.
- **Longer references** — `docs/` in the relevant repo, or `AGENTS.md` for cross-cutting agent conventions.

If a tool-specific memory dir exists from prior sessions, migrate its content (descriptions → `bd remember`; bodies that are durable references → `docs/`) and delete the dir.

## Blueprint specifics

- Per-system files (`packages/*`, `devshell.nix`, `checks/*`) receive `{ pkgs, inputs, flake, system, perSystem, pname, ... }`.
- `modules/nixos/<name>.nix` surfaces as `nixosModules.<name>` and `modules.nixos.<name>`.
- CriomOS exposes `nixosConfigurations.target` only — no `lib/default.nix`, `hosts/`, or `crioZones.*`. Lojix projects cluster proposals outside this repo and overrides the `horizon` / `system` inputs.
