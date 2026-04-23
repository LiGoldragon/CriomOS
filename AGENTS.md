# Agent Bootstrap — CriomOS

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

## Blueprint specifics

- Per-system files (`packages/*`, `devshell.nix`, `checks/*`) receive
  `{ pkgs, inputs, flake, system, perSystem, pname, ... }`.
- `modules/nixos/<name>.nix` surfaces as `nixosModules.<name>` and
  `modules.nixos.<name>`.
- `lib/default.nix` surfaces as `lib`.
- Custom outputs (like `crioZones`) are merged into blueprint's return
  value in `flake.nix`.
