# Project design review

## Scope

Review pass over the live CriomOS repo: flake surface, module aggregate,
deploy path, documentation authority, reports, and the strongest module
patterns. This is not a full line-by-line audit of every NixOS option.

## Executive read

The best design in the repo is the current three-axis orchestration shape:
`system`, `pkgs`, and `horizon` are separate flake inputs, and CriomOS exposes a
single `nixosConfigurations.target` whose identity comes from the projected
horizon. That is the right abstraction. It preserves network neutrality,
keeps host identity out of the filesystem, and creates a real evaluation-cache
boundary between package set, target system, and node horizon.

The largest problem is not the core architecture. The largest problem is that
several authority surfaces still describe the retired `crioZones` /
`lib.mkHorizon` model. The repo therefore has two stories at once: README and
`flake.nix` describe the current lojix-driven target model; `AGENTS.md`,
`docs/ROADMAP.md`, the bottom of `docs/GUIDELINES.md`, and
`packages/criomos-deploy/` still point readers and tools back toward the old
model. That drift is now dangerous because it can make agents implement the
wrong architecture.

## Good design

### 1. The three-flake split is genuinely good

`flake.nix` has the right high-level shape:

- `inputs.system` is a tiny content-addressed system tuple.
- `inputs.pkgs` owns nixpkgs instantiation for that system.
- `inputs.horizon` owns the per-deploy projected node view.
- `nixosConfigurations.target` is the only system configuration.

This gives a clean answer to the fundamental question: "what changes when a
node changes?" Only horizon changes. "What changes when a system tuple changes?"
Only system and pkgs. "What changes when CriomOS source changes?" The platform
module graph changes, but not the cluster truth source. That is the kind of
architecture that stays understandable under repeated deploy pressure.

### 2. Network-neutrality is correctly embodied in the main path

The current README states the invariant clearly: no `hosts/`, no cluster/node
enumeration, one target configuration, horizon decides identity. The live
`flake.nix` follows that. The module aggregate takes `horizon` as a special arg
and modules read `horizon.node`, `horizon.exNodes`, and `horizon.users`.

This is much stronger than the old `crioZones.<cluster>.<node>` output model.
`crioZones` was network-neutral by convention; the current model is
network-neutral by construction.

### 3. Home ownership boundary is right

`modules/nixos/userHomes.nix` consumes
`inputs.criomos-home.homeModules.default` and deliberately does not pass
CriomOS's own `inputs` through `extraSpecialArgs`, because CriomOS-home's
wrapper owns its own flake inputs. That comment is excellent: it names the
failure mode and prevents a subtle cross-repo input-shadowing bug.

This is the right shape for "system owns user creation and HM attachment;
CriomOS-home owns home behavior."

### 4. `modules/nixos/nix.nix` has real operational knowledge in it

The distributed-build configuration is not just a pile of Nix options. It
records the trust model: build receivers are gated on `isBuilder`, dispatchers
come from horizon, `nix.sshServe` uses restricted `nix-ssh`, dispatcher host
keys are the daemon identity, and known-hosts entries are generated so the
root daemon cannot hang on an interactive prompt.

That is good infrastructure design: the module encodes the deployment
contract, not just the local service configuration.

### 5. `crioZones.nix` as a tombstone is the right instinct

Keeping a small tombstone for a retired public shape is useful. It prevents a
future reader from recreating the old enumeration model accidentally. The
problem is not the tombstone; the problem is that other authority surfaces did
not move with it.

## Gaps and bad designs

### 1. Hard authority drift: AGENTS and docs still command the retired model

`AGENTS.md` still says any input with `NodeProposal` is a cluster and every
node gets `crioZones.<cluster>.<node>.*`. It also says custom outputs like
`crioZones` are merged into blueprint's return value.

`docs/ROADMAP.md` still lists `lib/default.nix`, `lib.mkHorizon`, and
`crioZones.nix` as active wiring work. `docs/GUIDELINES.md` still describes
`lib.discoverClusters`, `lib.mkHorizon`, `crioZones.*.os`,
`crioZones.*.deployManifest`, and `packages/criomos-deploy/` as the build and
deploy authority.

Those statements conflict with `README.md`, `flake.nix`, and the
`crioZones.nix` tombstone. Because `AGENTS.md` is the single source of truth for
agents, this is the most urgent design gap in the repo.

Correct frame: CriomOS exposes `nixosConfigurations.target`; lojix projects
horizon and system inputs; no cluster discovery happens in CriomOS.

### 2. `packages/criomos-deploy` is stale enough to be harmful

`packages/criomos-deploy/deploy.sh` builds
`#crioZones.<cluster>.<node>.fullOs`, but `crioZones.nix` is intentionally empty
and the README says lojix is the entry point. This package is therefore not a
legacy helper; it is an attractive broken deploy path shipped in
`environment.systemPackages` by `modules/nixos/normalize.nix`.

It should either be deleted, converted into a thin wrapper around `lojix-cli`,
or hidden behind an explicit "retired" tombstone. Leaving it installed means a
human or agent can reach for it and get a failure that looks like a deploy
problem rather than an obsolete-interface problem.

### 3. The flake currently does not enumerate cleanly

`nix flake show --json` fails while evaluating `checks/librist.nix`:
blueprint calls the check with its normal per-system argument set, but the file
requires direct arguments `librist`, `writeScriptBin`, and `mksh`. That shape
does not match the repo's blueprint convention.

`checks/pki-bootstrap.nix` looks even older: it imports paths like
`../clavifaber.nix` and `../mkCriomOS/constants.nix`, neither of which matches
the current repo layout. The checks directory is therefore not a trustworthy
quality gate today.

This matters because flake enumeration is often the cheapest smoke test for
whether the repo's public surface is coherent.

### 4. `modules/nixos/criomos.nix` still has impossible fallback shape

The aggregate has `{ config, lib, horizon ? null, ... }`. Per the current
design, horizon is mandatory: the flake's default horizon input throws if not
overridden, and lojix always supplies a real horizon. The `? null` fallback is
therefore a stale defensive habit and contradicts the stricter rule already
captured in report 0034.

This is small mechanically, but it is a design smell because it weakens the
contract at the top of the module tree.

### 5. `llm.nix` embeds secrets and large model policy too directly

`modules/nixos/llm.nix` reads `apiKey` from
`CriomOS-lib/data/largeAI/llm.json` and passes it into the systemd unit's
command line as `--api-key`. Even if the key is local-only, this makes the key
part of declarative config and likely visible through systemd metadata. The
model list and router policy living in CriomOS-lib is reasonable; secret
material should not follow the same path.

Better frame: CriomOS-lib can define model inventory and non-secret defaults;
the runtime secret should come from an age/sops/gopass-backed file or a
credential mechanism, with the unit using an environment file or systemd
credential rather than argv.

### 6. Router module has real host facts hidden under model names

`modules/nixos/router/default.nix` maps machine model strings to interface
names and WiFi properties. This is better than keying off node names, but it
still conflates "hardware model" with "this physical node's observed interface
layout." Two machines with the same model can have different NIC names, and a
single machine can change interface names after firmware/kernel changes.

The rule should be: durable hardware facts can live in horizon machine data;
deployment-specific interface roles (`wan`, `lan`, `wlan`) should be explicit
node horizon fields or emitted by a hardware scan tool. The existing
`criomos-hw-scan` bead points in that direction.

### 7. Some modules still carry unresolved local hacks

Examples:

- `normalize.nix` has a udev rule commented "What is this for?"
- `metal/default.nix` has `hasTouchpad = true`.
- `metal/default.nix` enables all firmware with a TODO to tune per model.
- `metal/default.nix` enables printing service globally, with only drivers
  gated by `wantsPrinting`.

These are not architectural failures by themselves, but they are places where
the horizon contract is not yet carrying enough truth, or where closure policy
has not been made explicit. Each should either move into horizon data or become
a deliberate documented platform default.

## Existing reports: keep, but demote some authority

Reports 0004 and 0005 are still useful historical records, but parts of them
are superseded by the current lojix-cli implementation and the README's
target-only shape. They should not be treated as current instructions.

Report 0034 is high-value because it captures process and design mistakes that
are still relevant: stale lojix docs, survive-disconnect, `boot-once` semantics,
and the "no impossible fallback" rule.

## Recommended next work

1. Update `AGENTS.md` to make the lojix-driven target model the hard rule:
   no `NodeProposal` discovery in CriomOS, no `crioZones` output contract,
   `nixosConfigurations.target` is the public system surface.
2. Rewrite the stale tail of `docs/GUIDELINES.md` around lojix and
   `nixosConfigurations.target`; delete references to `lib.mkHorizon`,
   `lib.discoverClusters`, and `crioZones.*`.
3. Decide whether `docs/ROADMAP.md` should be deleted or reduced to a pointer
   to beads plus the live README architecture. Its Phase 1/4 content is now
   actively misleading.
4. Remove or tombstone `packages/criomos-deploy`, or replace it with a wrapper
   that execs `lojix-cli` with the current pinned-rev discipline.
5. Fix or delete `checks/librist.nix` and `checks/pki-bootstrap.nix` so
   `nix flake show --json` and `nix flake check` become meaningful again.
6. Remove `horizon ? null` from `modules/nixos/criomos.nix`.
7. Split LLM runtime secret handling away from the model inventory file.
8. Move router interface role facts out of model-name lookup and into horizon
   or a generated hardware scan output.

## Bottom line

CriomOS has a strong core: one target, external horizon projection, separate
system/pkgs/horizon cache axes, and clean ownership boundaries with
CriomOS-home, CriomOS-lib, horizon-rs, and lojix-cli. The design that deserves
protection is already visible.

The repo now needs an authority cleanup. The biggest risk is not a bad new
abstraction; it is stale documentation and stale helper packages causing future
work to resurrect an architecture that the live flake has already left behind.
