# CriomOS

NixOS platform — modules + module aggregate. Deploys are driven by a
separate orchestrator (`lojix-cli`) that projects a cluster proposal
into a per-(cluster, node) horizon and invokes nix against this repo.

**Status:** active. The previous repo is archived at
[`criomos-archive`](../criomos-archive/) (carries the historical
multi-cluster `crioZones` mechanism; superseded — see
[`crioZones.nix`](crioZones.nix) tombstone).

## How it's used

CriomOS isn't built directly. The orchestrator (`lojix-cli`) is the
entry point:

1. Reads a cluster proposal nota (e.g.
   [`goldragon/datom.nota`](../goldragon/datom.nota)) and a node name.
2. Projects the proposal via `horizon-lib` (in-process Rust) into a
   per-(cluster, node) horizon JSON.
3. Writes a small horizon flake at
   `~/.cache/lojix/horizon/<cluster>/<node>/`.
4. Invokes nix against `github:LiGoldragon/CriomOS` with
   `--override-input horizon path:<that-cache-dir>`.

User-facing form:

```
lojix build|eval|deploy --cluster <C> --node <N> --source <C>/datom.nota
```

CriomOS exposes one configuration —
`nixosConfigurations.target.config.system.build.toplevel`. The
`horizon` input override picks which (cluster, node) it materialises.

## Network-neutral by construction

CriomOS does NOT enumerate hosts. Cluster + node identity live in the
horizon (the projected per-deploy view). The same CriomOS source builds
any node of any cluster — only the horizon override differs.

Blueprint's `hosts/<name>/` convention is deliberately **not** used: it
bakes host identity into the platform repo, contradicting
network-neutrality.

## 3-flake architecture

The three orchestration axes evaluate and cache independently:

| input | what it is | when it changes |
|---|---|---|
| [`system`](stubs/no-system/) | tiny flake whose only output is a system tuple (`x86_64-linux`, `aarch64-linux`) | per supported arch |
| [`pkgs`](pkgs-flake/) | wrapper that instantiates nixpkgs for a given system | per (nixpkgs-rev, system) |
| [`horizon`](stubs/no-horizon/) | the projected per-(cluster, node) view | per deploy |

Each is content-addressed. Identical input → eval-cache hit. The
`pkgs` axis caches across deploys with the same nixpkgs+system;
`horizon` changes don't invalidate `pkgs`.

`system` and `pkgs` default to local stubs in this repo. `horizon`
defaults to a stub that throws — overrides are required at build time
(lojix-cli does this automatically).

## Sibling repos

- [`LiGoldragon/CriomOS-home`](https://github.com/LiGoldragon/CriomOS-home) —
  home profile. Own inputs (niri, noctalia, stylix, mentci-tools, …).
  CriomOS consumes `homeModules.default`.
- [`LiGoldragon/CriomOS-lib`](https://github.com/LiGoldragon/CriomOS-lib) —
  shared helpers (`importJSON`, `mkJsonMerge`) + cross-repo data
  (`data/largeAI/llm.json`). Consumed by both CriomOS and CriomOS-home.
- [`LiGoldragon/horizon-rs`](https://github.com/LiGoldragon/horizon-rs) —
  horizon schema + projection logic (Rust). Single source of truth
  for the typed schema.
- [`LiGoldragon/lojix-cli`](https://github.com/LiGoldragon/lojix-cli) —
  the orchestrator (Rust). Today: standalone CLI; eventually a thin
  client to `lojix` (the daemon, planned).
- [`LiGoldragon/clavifaber`](https://github.com/LiGoldragon/clavifaber) —
  GPG → X.509 WiFi PKI tool. Consumed in `modules/nixos/complex.nix`.
- [`LiGoldragon/brightness-ctl`](https://github.com/LiGoldragon/brightness-ctl) —
  backlight + idle-dim daemon. Consumed in `modules/nixos/metal/`.
- [`LiGoldragon/CriomOS-emacs`](https://github.com/LiGoldragon/CriomOS-emacs)
  *(planned)* — replaces legacy `pkdjz/mkEmacs`. Will be consumed by
  CriomOS-home.

## Layout

Blueprint conventions for everything except the orchestration stubs:

- `packages/<name>.nix` → `packages.<system>.<name>`
- `modules/nixos/<name>.nix` → `nixosModules.<name>`
- `devshell.nix`, `formatter.nix`, `checks/<name>.nix`

CriomOS-specific:

- `modules/nixos/criomos.nix` — the platform module aggregate.
- `modules/nixos/userHomes.nix` — wraps CriomOS-home for per-user
  home-manager activations.
- `stubs/{no-system,no-horizon}/` — default stub inputs (overridden
  by lojix-cli).
- `pkgs-flake/` — the `pkgs` axis, consumed via `path:./pkgs-flake`.
- `data/` — cross-flake data files referenced from modules.

No `modules/home/` here — it lives in `CriomOS-home`. No `hosts/` —
network-neutral.

## Conventions

- Jujutsu (`jj`) for all VCS. Never `git` CLI.
- Mentci three-tuple commit format.
- Never print Nix store paths into agent context; use shell vars /
  subshells.
- See [`AGENTS.md`](AGENTS.md) for the full agent ruleset (reports,
  beads, layers, etc.).
- See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the deeper repo-role
  description and cross-cutting context.
