# Home-Off System Surface

## Question

`lojix-cli` needs a three-way deploy-kind split:

| kind | desired CriomOS behavior |
|---|---|
| `FullOs` | build the normal system generation, including embedded Home Manager |
| `OsOnly` | build a system generation that does not contain embedded Home Manager activation |
| `HomeOnly` | build one user's Home Manager activation package from the normal home-enabled eval |

The research question is whether CriomOS can support `OsOnly` without
breaking existing builds, and whether that should be done by adding a
second `nixosConfigurations` entry.

## Existing Contract

Current public surface:

```text
nixosConfigurations.target
```

Current system toplevel attr:

```text
nixosConfigurations.target.config.system.build.toplevel
```

Current home activation attr:

```text
nixosConfigurations.target.config.home-manager.users.<user>.home.activationPackage
```

CriomOS imports the Home Manager NixOS module in [flake.nix](../flake.nix)
and imports [modules/nixos/userHomes.nix](../modules/nixos/userHomes.nix)
from the CriomOS aggregate. `userHomes.nix` maps `horizon.users` into
`home-manager.users`, so the existing `target` is already the
`FullOs` shape.

The repo contract says the single public system surface is
`nixosConfigurations.target`. Adding another `nixosConfigurations`
member is technically additive for Nix, but it expands the public
contract.

## Can We Add Two `nixosConfigurations`?

Technically, yes.

The flake could expose:

| attr | meaning |
|---|---|
| `nixosConfigurations.target` | current home-enabled system |
| `nixosConfigurations.targetHomeOff` | same system with Home Manager omitted |

Existing callers building `target` would keep working. If both
configurations are generated from one internal target factory, drift can
be controlled.

But this is not the recommended path.

Why:

- It violates the documented one-surface rule.
- It makes deploy kind an output-name choice instead of input data.
- It gives future agents and operators two system surfaces to choose
  from, which is exactly what the network-neutral `target` convention
  was avoiding.
- It would require documentation updates weakening the current contract.
- `HomeOnly` would still build from the home-enabled target, so the CLI
  would now need to know both output names and which deploy kind maps to
  which one.

Two configs are acceptable only if Li explicitly decides the
single-surface invariant is no longer worth preserving.

## Recommended Shape: One Target, Deployment Input

Keep:

```text
nixosConfigurations.target
```

Add a small flake input that carries operation shape, with a default
stub that preserves current behavior:

```text
inputs.deployment.deployment.includeHome = true
```

`lojix-cli` overrides that input per request:

| deploy kind | deployment input | build attr |
|---|---|---|
| `FullOs` | `includeHome = true` | system toplevel |
| `OsOnly` | `includeHome = false` | system toplevel |
| `HomeOnly` | `includeHome = true` | user activation package |

This keeps `target` as the only public NixOS configuration. Deploy kind
becomes another content-addressed input, like `horizon` and `system`.

## Why Not Reuse Existing Inputs?

Do not put this in `horizon`.

`horizon` is projected cluster truth for a `(cluster, node)` viewpoint.
Whether this invocation wants home enabled is operational intent, not
cluster truth. Encoding it in `horizon` would make the same node have
different projected facts depending on the deploy action.

Do not put this in `system`.

`system` is intentionally only the target system tuple. `CriomOS-pkgs`
follows it so pkgs evaluation caches across all nodes with the same
architecture. If deployment shape rides on `system`, the pkgs axis
becomes contaminated by a non-architecture choice.

Use a separate `deployment` input.

## Minimal CriomOS Adaptation

The default behavior must remain home-enabled. The low-risk change is:

1. Add a local default deployment stub under `stubs/`.
2. Add a `deployment` input pointing at that stub.
3. Read `inputs.deployment.deployment.includeHome`, defaulting to true.
4. Import `inputs.home-manager.nixosModules.home-manager` only when
   `includeHome` is true.
5. Import `modules/nixos/userHomes.nix` only when `includeHome` is true.
6. Keep all existing attrs and build paths unchanged.

The important split is that both Home Manager pieces must be gated:

| piece | why gate it |
|---|---|
| Home Manager NixOS module | otherwise `home-manager.*` options and activation machinery exist |
| `userHomes.nix` | otherwise CriomOS still declares `home-manager.users` |

Leaving the Home Manager input in `flake.lock` is fine. The goal is
not to remove every reference to the upstream input; the goal is to
avoid building and activating embedded home profiles in the system
generation.

## Compatibility Properties

This shape preserves existing behavior by default:

| existing behavior | preserved by |
|---|---|
| `target` still exists | no new required output name |
| normal builds include home | default stub has `includeHome = true` |
| home activation package attr exists in normal eval | home-enabled default remains |
| no cluster/node names in CriomOS | deployment input has no identity |
| pkgs cache axis remains per system tuple | deployment does not affect `system` input |

`OsOnly` becomes opt-in and requires a new `lojix-cli` override:

```text
--override-input deployment path:<lojix-generated-deployment-dir>
```

That is a Nix invocation flag inside the implementation, not a user CLI
flag.

## What `OsOnly` Means

Initial `OsOnly` should mean:

- no embedded Home Manager NixOS module;
- no `home-manager.users`;
- no boot-time Home Manager activation units;
- no `home-manager.users.<user>.home.activationPackage` attr.

It should not initially mean "minimal closure with every home-adjacent
system service removed." For example, `programs.dconf.enable = true`
currently lives in `criomos.nix` for Home Manager compatibility, but it
is still a normal system service. Gating those extra support services is
a later closure-shrink decision, not required for correct home-off
semantics.

## Test Plan

After implementation, test both shapes from a pushed revision:

| test | expected result |
|---|---|
| default deployment input | system toplevel attr still evaluates/builds as before |
| `includeHome = true` override | same behavior as default |
| `includeHome = false` override | system toplevel evaluates/builds without Home Manager |
| `includeHome = false` plus home activation attr | fails clearly because the attr is absent |
| normal home activation attr | still exists under home-enabled eval |

Also inspect the evaluated system service names for the home-off eval:
there should be no Home Manager per-user activation service.

## Recommendation

Do not add a second `nixosConfigurations` output unless the
single-surface rule is intentionally retired.

Implement home-off as a fourth deploy-time input axis:

```text
horizon    = projected cluster/node view
system     = target architecture tuple
pkgs       = nixpkgs instantiated for that tuple
deployment = operation shape, starting with includeHome
```

This is the least-breaking path: existing deploys remain `FullOs`, the
public output stays `target`, and `lojix-cli` gets an honest `OsOnly`
mode without pretending that skipping activation is enough.

