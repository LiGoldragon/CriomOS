# Agent Bootstrap — CriomOS

## First thing

Run `bd list --status open` to see what's already on the table.

Before making changes:

1. Read `docs/ROADMAP.md` — porting order and open tasks.
2. Read the design essay at `../criomos-archive/proposals/CRIOMOS-NEXT.md`.
3. Read `../horizon-rs/docs/DESIGN.md` for the horizon schema.
4. Read `/home/li/.claude/projects/-home-li-git-CriomOS/memory/MEMORY.md` and
   relevant memory files.

## Rust style

Any Rust written in this repo (`packages/brightness-ctl/`, `packages/clavifaber.nix`-consumed crate, future tools) follows
[`~/git/tools-documentation/rust/style.md`](../tools-documentation/rust/style.md):
methods on types, typed newtypes for domain values, single-object I/O,
`thiserror`-derived `Error` enums (no `anyhow`, no `eyre`), trait-domain rule.

## Hard architectural rules

- **Network-neutral.** CriomOS does NOT know the names of clusters or
  nodes. Any input with a `NodeProposal` attr is a cluster; every node in
  that proposal gets `crioZones.<cluster>.<node>.*`. Never introduce
  `hosts/<name>/` or any filesystem-keyed enumeration of live networks.
- **Home lives in `CriomOS-home`.** Do not add `modules/home/` here. Consume
  home via `inputs.criomos-home.homeModules.*`.
- **Horizon is external.** Schema + method logic live in `horizon-rs` (Rust).
  Nix only consumes the enriched horizon TOML (camelCase fields).

## Hard process rules (inherited from legacy CriomOS/AGENTS.md)

- Jujutsu only. Never `git` CLI.
- Push before building; build from origin with `--refresh`.
- Never put Nix store paths in conversation context — capture in shell vars.
- Never use `<nixpkgs>` / `NIX_PATH`; use flake attrs or `nix shell nixpkgs#jq`.
- Never run `switch-to-configuration switch` in a chroot.
- Never live-activate home-manager generations with compositor/input changes.
- Never SIGHUP niri.
- SSH keys only — no password auth, ever.

## Blueprint specifics

- Per-system files (`packages/*`, `devshell.nix`, `checks/*`) receive
  `{ pkgs, inputs, flake, system, perSystem, pname, ... }`.
- `modules/nixos/<name>.nix` surfaces as `nixosModules.<name>` **and**
  `modules.nixos.<name>`.
- `lib/default.nix` surfaces as `lib` (takes `{ flake, inputs, ... }` or `_`).
- Custom outputs (like `crioZones`) are merged into blueprint's return value
  in `flake.nix`.
