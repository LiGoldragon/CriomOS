# ARCHITECTURE — CriomOS

The host OS for the sema ecosystem. NixOS-based. Boots into a
pre-configured environment where criomed, lojixd, and sundry
nexus daemons run as the user-space layer.

CriomOS is **the consumer of lojix**, not a member of the criome
runtime. lojix-deploy (currently
[lojix](https://github.com/LiGoldragon/lojix)) materialises
CriomOS configurations.

## Role

A coherent platform target: the sema-ecosystem assumes a Unix
filesystem, systemd, a working nix-store, blake3 in scope, etc.
CriomOS provides those guarantees and folds in project-specific
modules (criomed service, nexusd service, lojix-store
mountpoint, …).

## What this repo defines

The host OS as nix flakes. Detailed design lives in
[`docs/`](docs/):

- `docs/GUIDELINES.md` — module authoring conventions.
- `docs/NIX_GUIDELINES.md` — nix idioms specific to this OS.
- `docs/ROADMAP.md` — feature staging.

`crioZones.nix` and `data/` carry the configuration substrate.

## What this repo does not define

- Sema, signal, or any application-layer record kind.
- The criomed daemon, lojixd daemon, or any sema-ecosystem
  binary.
- The deploy CLI — that's
  [lojix](https://github.com/LiGoldragon/lojix) (transitional).

## Status

CANON. Active host platform.

## Cross-cutting context

- CriomOS membership in the workspace:
  [mentci-next/docs/workspace-manifest.md](https://github.com/LiGoldragon/mentci-next/blob/main/docs/workspace-manifest.md)
- Project-wide architecture:
  [mentci-next/docs/architecture.md](https://github.com/LiGoldragon/mentci-next/blob/main/docs/architecture.md)
