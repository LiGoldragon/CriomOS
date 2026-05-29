# ARCHITECTURE — CriomOS

The host OS for the sema ecosystem. NixOS-based. Boots into a
pre-configured environment where criome, forge, and sundry
nexus daemons run as the user-space layer.

> **Scope: today, not eventually.** "criome" here is today's daemon
> (sema-ecosystem records validator) — see
> `~/primary/repos/criome/ARCHITECTURE.md`. CriomOS is **named after**
> the *eventual* Criome — the universal computing paradigm in Sema
> — but CriomOS today is pre-duct-tape: a NixOS-targeted host that
> uses transitional shims (ClaviFaber for key generation, lojix-cli
> for deploy, etc.) where eventual Criome's substrate will later
> sit. Eventually the OS is written in Sema; ClaviFaber-shaped shims
> are obsoleted by Criome's quorum-signature multi-sig system at
> that point. See `~/primary/ESSENCE.md` §"Today and eventually —
> different things, different names".

CriomOS is **the consumer of forge**, not a member of the criome
runtime. forge-deploy (currently `lojix-cli`) materialises
CriomOS configurations.

This repo doubles as the **CriomOS-cluster meta-repo** — it
hosts the symlink farm under `repos/` that exposes lore + the
CriomOS-cluster siblings
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

The configuration substrate is the lojix-projected `horizon` input,
the target `system` tuple input, the deployment-shape input, and the
NixOS modules in this repo.

CriomOS is network-neutral. Cluster node names are data flowing through
Horizon, never control-flow predicates inside the Nix engine. Modules may
render a node name as a hostname, identity, path component, or diagnostic
label, but role decisions must come from Horizon capabilities such as
tailnet client/controller or large-AI provider roles.

Router nodes treat local access as the recovery path during upgrades.
The primary LAN bridge accepts USB Ethernet adapters by driver family;
missing USB devices do not hold boot or network-online, and hotplugged
USB Ethernet devices join the bridge when they appear. A
Horizon-declared backup wireless interface runs as an independent
hostapd service bound to its device unit and triggered by a udev
`SYSTEMD_WANTS` rule, so missing USB Wi-Fi leaves the primary router
online and plugging the adapter in later starts the backup AP. Router network services avoid automatic restart-on-switch so
a new generation does not casually drop the live management path; reboot
or an explicit operator restart applies changed network policy.

## What this repo does not define

- Sema, signal, or any application-layer record kind.
- The criome daemon, forge daemon, or any sema-ecosystem
  binary.
- The deploy CLI — that's `github:LiGoldragon/lojix-cli`
  (transitional).

## Status

CANON. Active host platform.

## Cross-cutting context

- Workspace contract: lore's `AGENTS.md` (symlinked at `repos/lore/`).
- Project-wide architecture: criome's `ARCHITECTURE.md`.
- CriomOS membership in the broader workspace:
  workspace's `docs/workspace-manifest.md`.
