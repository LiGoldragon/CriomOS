# CriomOS

Canonical rewrite. The previous repo is archived at
[`criomos-archive`](../criomos-archive/). Uses the
[numtide/blueprint](https://github.com/numtide/blueprint) flake helper for
standard outputs (modules, packages, devshell, formatter, lib), with one
custom output on top: `crioZones.<cluster>.<node>.*`.

**Status:** scaffold. Work against [docs/ROADMAP.md](docs/ROADMAP.md).

**Design essay:** `proposals/CRIOMOS-NEXT.md` in the `criomos-archive` repo.

## Network-neutral by construction

CriomOS does NOT enumerate hosts. It is the *machinery* that produces
`crioZones.<cluster>.<node>.{os,fullOs,vm,home,deployManifest}` for any flake
input whose outputs expose a `NodeProposal` attr. The consumer's flake pins
whichever clusters it cares about:

```nix
# in a consumer flake:
inputs.maisiliym.url = "github:LiGoldragon/maisiliym";
inputs.criomos.url = "github:LiGoldragon/CriomOS";
# → crioZones.maisiliym.<node>.* is available, without CriomOS knowing
#   anything about maisiliym.
```

Blueprint's `hosts/<name>/` convention is deliberately **not** used: it bakes
host identity into the platform repo, which contradicts network-neutrality.
The cluster/node axis lives in the horizon (external input), not the filesystem.

## Sibling repos

- [`LiGoldragon/CriomOS-home`](https://github.com/LiGoldragon/CriomOS-home) — home
  profile. Own inputs (niri, noctalia, stylix, emacs, …). CriomOS
  consumes `homeModules.default`.
- [`criome/horizon-rs`](https://github.com/criome/horizon-rs) — horizon
  schema + method CLI (Rust). Single source of truth for types and the
  method DAG.
- [`LiGoldragon/clavifaber`](https://github.com/LiGoldragon/clavifaber) *(planned)* —
  GPG → X.509 WiFi PKI tool.
- [`LiGoldragon/CriomOS-emacs`](https://github.com/LiGoldragon/CriomOS-emacs)
  *(planned)* — replaces legacy `pkdjz/mkEmacs`. Consumed by CriomOS-home.

## Layout

Blueprint conventions for everything except crioZones:

- `packages/<name>.nix` → `packages.<system>.<name>`
- `modules/nixos/<name>.nix` → `nixosModules.<name>`
- `lib/default.nix` → `lib`
- `devshell.nix`, `formatter.nix`, `checks/<name>.nix`
- `crioZones.nix` → `crioZones.<cluster>.<node>.*` (custom output, layered on
  top of blueprint's return value in `flake.nix`).

No `modules/home/` here — it lives in `CriomOS-home`. No `hosts/` — see above.

## Conventions

- Jujutsu (`jj`) for all VCS. Never `git` CLI.
- Mentci three-tuple commit format.
- Never print Nix store paths into agent context; use shell vars / subshells.
