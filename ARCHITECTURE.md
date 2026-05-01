# ARCHITECTURE — CriomOS

The host OS for the sema ecosystem. NixOS-based. Boots into a
pre-configured environment where criome, forge, and sundry
nexus daemons run as the user-space layer.

CriomOS is **the consumer of forge**, not a member of the criome
runtime. forge-deploy (currently `lojix-cli`) materialises
CriomOS configurations.

This repo doubles as the **CriomOS-cluster meta-repo** — it
hosts the multi-root editor workspace + symlink farm under
`repos/` that exposes lore + the CriomOS-cluster siblings
(CriomOS-home, CriomOS-emacs, horizon-rs) and the transitional
deploy crates (lojix-cli, brightness-ctl, clavifaber). `nix
develop` / direnv entry refreshes the symlinks.

## Role

A coherent platform target: the sema-ecosystem assumes a Unix
filesystem, systemd, a working nix-store, blake3 in scope, etc.
CriomOS provides those guarantees and folds in project-specific
modules (criome service, nexus service, arca
mountpoint, …).

## What this repo defines

The host OS as nix flakes. Detailed design lives in
[`docs/`](docs/):

- `docs/GUIDELINES.md` — module authoring conventions.
- `docs/NIX_GUIDELINES.md` — nix idioms specific to this OS.
- `docs/ROADMAP.md` — feature staging.

The configuration substrate is the lojix-projected `horizon` input plus
the NixOS modules in this repo.

## What this repo does not define

- Sema, signal, or any application-layer record kind.
- The criome daemon, forge daemon, or any sema-ecosystem
  binary.
- The deploy CLI — that's
  [lojix-cli](https://github.com/LiGoldragon/lojix-cli) (transitional).

## Status

CANON. Active host platform.

## Cross-cutting context

- Workspace contract: lore's `AGENTS.md` (symlinked at `repos/lore/`).
- Project-wide architecture: criome's `ARCHITECTURE.md`.
- CriomOS membership in the broader workspace:
  workspace's `docs/workspace-manifest.md`.
