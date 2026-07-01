# CriomOS

NixOS platform — modules + module aggregate. Deploys are driven by Lojix,
which projects a cluster proposal into a per-(cluster, node) horizon and
invokes nix against this repo with deployment-shape inputs.

**Status:** active. The previous repo is archived at
[`criomos-archive`](../criomos-archive/).

## How it's used

CriomOS isn't built directly. Lojix is the deploy entry point:

1. Reads a cluster proposal nota and a node name.
2. Projects the proposal via `horizon-rs` into a per-(cluster, node)
   horizon JSON.
3. Writes small override flakes for the horizon, system tuple, and
   deployment shape.
4. Invokes nix against `github:LiGoldragon/CriomOS` with those override
   inputs.

Privileged deploy admission is a single typed request passed to
`meta-lojix`; observations use the ordinary `lojix` query interface:

```
meta-lojix "(Deploy (Host (<cluster> <node> CompleteHost <proposal-source> <criomos-flake-ref> <host-action> RequireImmutable <builder> [] None)))"
meta-lojix "(Deploy (Host (<cluster> <node> BaseHost <proposal-source> <criomos-flake-ref> <host-action> RequireImmutable <builder> [] None)))"
meta-lojix "(Deploy (UserEnvironment (<cluster> <node> <user> <proposal-source> <criomos-flake-ref> <user-environment-action> RequireImmutable <builder> [])))"
lojix "(Query (ByNode (<cluster> <node> None)))"
```

`DeployAccepted DeployHandle` is admission evidence only. Operators use typed
Lojix observations to prove build, copy, activation, profile, and generation
state.

CriomOS exposes one configuration —
`nixosConfigurations.target.config.system.build.toplevel`. The
`horizon` input override picks which (cluster, node) it materialises;
the `deployment` input picks the operation shape, such as `CompleteHost`
or `BaseHost`.

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
  the typed deploy daemon and its `lojix` / `meta-lojix` clients.
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
