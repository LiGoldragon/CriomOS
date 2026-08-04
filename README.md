# CriomOS

NixOS platform — modules + module aggregate. Deploys are driven by Lojix,
which projects a cluster proposal into a per-(cluster, node) horizon and
invokes nix against this repo with deployment-shape inputs.

**Status:** active. The previous repo is archived at
[`criomos-archive`](../criomos-archive/).

## How it's used

Normal deployments are Lojix-driven. The maintained daemon-free bootstrap
re-export below is a distinct, explicitly authorized first-bootstrap or
recovery surface:

1. Reads a cluster proposal nota and a node name.
2. Projects the proposal via `horizon-rs` into a per-(cluster, node)
   horizon JSON.
3. Writes small override flakes for the horizon, system tuple, and
   deployment shape.
4. Invokes nix against `github:LiGoldragon/CriomOS` with those override
   inputs.

For a fresh, explicitly-authorized first bootstrap, use this flake's exact
re-export of the maintained v0.17.2 `lojix-bootstrap` app. It accepts one inline
`BootstrapRun` DOTOS object only—no installed daemon, daemon socket, request
file, flag, local store, route, account, or path default. `BuildOnly` is the
exact build-only variant; `BootOnce` names either an explicit remote transport
pair or the distinct audited local backend. Both require a new GC-root and
terminal-evidence path; the root is made durable before any activation.

```text
nix run github:LiGoldragon/CriomOS/<rev>#lojix-bootstrap -- 'BootstrapRun.{<request-id> BootOnce.{<explicit-input> <explicit-builder> <explicit-test-plan> <explicit-backend> <journal-parent> <new-gc-root> <new-evidence>}}'
```

See Lojix's `README.md` for the full positional schema. This is the maintained
operator surface; the old handwritten `meta-lojix` request forms are not a
bootstrap interface.

Each deployment supplies its exact flake output selector. `Horizon` input mode
causes Lojix to materialise the request's projection; `Direct` does not. The
daemon never derives a target attribute, Nix-store URI, SSH destination, or
builder specification from CriomOS cluster/node names. An explicitly requested
`root@…` destination is valid, but it is never a default.

## Network-neutral by construction

CriomOS does NOT enumerate hosts. Cluster + node identity live in the
horizon (the projected per-deploy view). The same CriomOS source builds
any node of any cluster — only the horizon override differs.

Blueprint's `hosts/<name>/` convention is deliberately **not** used: it
bakes host identity into the platform repo, contradicting
network-neutrality.

## Input Axes

The orchestration axes evaluate and cache independently:

| input | what it is | when it changes |
|---|---|---|
| [`system`](stubs/no-system/) | tiny flake whose only output is a system tuple (`x86_64-linux`, `aarch64-linux`) | per supported arch |
| `pkgs` (`github:LiGoldragon/CriomOS-pkgs`) | wrapper that instantiates nixpkgs for a given system, plus overlays | per (nixpkgs-rev, system, overlays) |
| [`horizon`](stubs/no-horizon/) | the projected per-(cluster, node) view | per deploy |
| [`deployment`](stubs/default-deployment/) | operation shape, currently `includeHome` and `includeAllFirmware` | per deploy kind |

Each is content-addressed. Identical input → eval-cache hit. The
`pkgs` axis caches across deploys with the same nixpkgs+system;
`horizon` and `deployment` changes don't invalidate `pkgs`.

`system` and `pkgs` default to local stubs in this repo. `horizon`
defaults to a stub that throws; `deployment` defaults to historical
home-enabled behavior. Lojix overrides the inputs that are specific to
the requested deploy.

## Sibling repos

- `LiGoldragon/CriomOS-home` — home profile. Own inputs
  (niri, noctalia, stylix, …). CriomOS consumes `homeModules.default`.
- `LiGoldragon/CriomOS-lib` —
  shared helpers (`importJSON`, `mkJsonMerge`) + cross-repo data
  (`data/largeAI/llm.json`). Consumed by both CriomOS and CriomOS-home.
- `LiGoldragon/CriomOS-pkgs` —
  the `pkgs` axis. Own repo so CriomOS
  edits don't invalidate the pkgs eval cache.
- `LiGoldragon/horizon-rs` —
  horizon schema + projection logic (Rust). Single source of truth
  for the typed schema.
- `LiGoldragon/lojix` —
  the typed deploy daemon and its `lojix` / `meta-lojix` clients, plus the
  maintained daemon-free `lojix-bootstrap` flake app re-exported here.
- `LiGoldragon/clavifaber` —
  GPG → X.509 WiFi PKI tool. Consumed in `modules/nixos/complex.nix`.
- `LiGoldragon/brightness-ctl` —
  backlight + idle-dim daemon. Consumed in `modules/nixos/metal/`.
- `LiGoldragon/CriomOS-emacs`
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
- `stubs/{no-system,no-horizon,default-deployment}/` — default
  orchestration inputs.
No `modules/home/` here — it lives in `CriomOS-home`. No `hosts/` —
network-neutral.

## Conventions

- Jujutsu (`jj`) for all VCS. Never `git` CLI.
- Mentci three-tuple commit format.
- Never print Nix store paths into agent context; use shell variables /
  subshells.
- See [`AGENTS.md`](AGENTS.md) for the full agent ruleset (reports,
  beads, layers, etc.).
- See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the deeper repo-role
  description and cross-cutting context.
