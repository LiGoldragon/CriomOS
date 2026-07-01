# ARCHITECTURE — CriomOS

The host OS for the sema ecosystem. NixOS-based. Boots into a
pre-configured environment where criome, forge, and sundry
nexus daemons run as the user-space layer.

> **Scope: today, not eventually.** "criome" here is today's daemon
> (sema-ecosystem records validator) — see
> `~/primary/repos/criome/ARCHITECTURE.md`. CriomOS is **named after**
> the *eventual* Criome — the universal computing paradigm in Sema
> — but CriomOS today is pre-duct-tape: a NixOS-targeted host that
> uses transitional shims (ClaviFaber for key generation, Lojix for deploy,
> etc.) where eventual Criome's substrate will later sit. Eventually the OS is
> written in Sema; ClaviFaber-shaped shims
> are obsoleted by Criome's quorum-signature multi-sig system at
> that point. See `~/primary/ARCHITECTURE.md` §"Workspace vision and intent".

CriomOS is **the consumer of forge**, not a member of the criome
runtime. Lojix materialises CriomOS configurations.

This repo doubles as the **CriomOS-cluster meta-repo** — it
hosts the symlink farm under `repos/` that exposes lore + the
CriomOS-cluster siblings
(CriomOS-home, CriomOS-emacs, horizon-rs) and the deploy/support crates
(lojix, brightness-ctl, clavifaber). `nix
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

A large-AI node may additionally carry a sturdy backup admin network
built from attached USB devices: a USB Wi-Fi adapter serves a backup
access point and a pair of USB Ethernet adapters form a master router
interface. This backup runs at system level on plain
`systemd-networkd` with simple DHCP and forwarded DNS, deliberately
independent of the main kea / dnsmasq / hostapd stack so a switchover
cannot take it down. The backup devices stay optional: their absence
must not fail router networking, and devices plugged in after boot are
configured when they appear. The backup access point's SSID and
passphrase are secrets held through sops-nix, never in plaintext
source.

Deploying to a large-AI node (Horizon role `large-ai-node`,
`NodeService::LargeAi`) must preserve that node's network
connectivity. A live `Switch` restarts hostapd and dnsmasq and drops
the management connection, so until console or out-of-band access and
operator sign-off exist, use the safe `BootOnce` / boot-mode
activation path rather than `Switch`, and avoid staging an unverified
generation for an unintended reboot. A full-OS deploy updates the
production CriomOS flake lock before deploying the node. Role
decisions name the role, not the host: references that should be
role-level are stated against `large-ai-node` rather than a concrete
node name.

Large-AI provider nodes serve the shared model catalog through
llama.cpp's router mode. The deployed llama.cpp package is part of the
model compatibility contract: listing a model in the catalog is not
enough unless the serving binary can read that model's GGUF architecture
and chat template. Gemma 4 entries require a llama.cpp generation with
`gemma4` architecture support, currently carried by the Strix Halo
package override at b9404 or newer.

Large-AI model identifiers include quantization when multiple variants of
the same base model are deployed. The shared catalog may keep legacy
aliases, but new variants use names such as `gemma-4-26b-a4b-bf16`,
`gemma-4-26b-a4b-ud-q4-k-xl`, and `gemma-4-26b-a4b-ud-q8-k-xl` so
clients can choose the quality / speed / residency trade-off explicitly.
The large-AI model inventory carries the multimodal Gemma family — the
dense maximum-quality model and the MoE fast model — at `bf16` with an
`f16` vision projector, and exposes several quantization variants as
separate selectable models in the llama-server router, each named by
quant in its model id and sharing one vision projector per base model
so a client picks quality versus speed. Local Pi and agent sessions
select these as a local provider. The catalog prefers one curated
best-and-latest model per capability over near-duplicates, even though
candidate models may be prefetched freely and need not run
simultaneously. Video speech-to-text is tiered: the best path runs on
the large-AI node, with a smaller local model for weaker machines.

Heavy node work runs where the data already lives. Model prefetch,
fixed-output hash discovery, large builds, and evaluations run on the
node that holds the model files — the large-AI node itself — never on
an operator workstation or a coordinating machine. Node NixOS
configurations build and realize on the target node (or its configured
remote builder); coordinating machines evaluate only, because realizing
a model-bearing closure elsewhere would drag tens of gigabytes of model
data onto the wrong store. Large fixed-output model downloads and hash
discovery run on the node over its wired LAN as durable, target-side
systemd work with a target-side periodic monitor, surviving SSH drops.
Quantized variants install through the large-AI model inventory deploy
path; disruptive promotions launch as durable transient systemd units.

### Node feature: VM-based testing

CriomOS carries a node feature for VM-based testing, and the choice of
the best Linux VM technology for it is owned by CriomOS. The feature
provides a real display / GPU / DRM-capable VM rather than a headless
one — headless wlroots lacks `wlr-gamma-control`, so it cannot exercise
the visual surfaces under test. The VM is Nix-native, CI-automatable,
and interactively viewable, so a test can launch the real application,
run the component, and observe the actual visual effect — theme,
warmth, brightness — while watching for freezes and errors. `chroma`
is the first target; the test sandboxes run via systemd on a node such
as the AI node.

The VM-testing feature carries a per-node GPU-passthrough option (VFIO
GPU passthrough, used for the gamma visual test). Passthrough is
disabled on an AI node, whose powerful GPU must not be monopolized by a
`vfio-pci` passthrough: the AI node runs the non-gamma harness and the
routed test VM, while the gamma passthrough test runs on a node where
passthrough is acceptable.

### Node feature: website hosting

CriomOS provides a website-hosting node service so a source can be
rendered and served from a node. The service supports multiple renderer
variants; the standard default is a markdown-based static site in the
Jekyll mould. The implementation is held to the most reliable and
secure approach. This is the first concrete role for a low-trust cloud
node such as `doris`.

### Node secrets, auth, and privileged access

Node secrets live in declarative secret stores, never in plaintext
source or logs. A randomly generated, human-readable backup Wi-Fi
password is stored through sops-nix. An AI node enforces its API auth
with a gopass-fed token: the node's API-key file and the client
wrappers read from the same gopass entry, and a mint tool generates the
token and writes it to that gopass path.

Privileged and root-level operations on cluster hosts are performed by
SSH-ing into the host root account authenticated with the operator SSH
key — `ssh root@<host>` for any host. This is the standing
privileged-access mechanism across the workspace; `sudo` is not the
access path.

### Battery care and bare-metal gating

A laptop-class node keeps ThinkPad battery-care charge thresholds
enabled for ordinary use, preferring a 75–80 percent conservation
window over routine full charging. Synthetic bare-metal firmware-gating
work stays generic, avoids unrelated unfree firmware, and is verified
with constrained Nix checks.

### Direction: the LojixOS split

A planned rename-and-configuration split moves the generic OS substrate
into `LojixOS`, leaving CriomOS as a per-deploy configuration crate
holding a thin NOTA data tree that lojix precompiles into binary
config. Per-node configuration is declared in the Horizon cluster data.
Cloud-node OS images live in CriomOS as a minimal cloud-node profile,
built declaratively with an image builder — not by snapshotting a
converted running droplet — and content-sized to boot fast on the
smallest sensible droplet. CriomOS owns the image definition and the
provider-format build; the cloud daemon owns snapshot-id selection and
provisioning, referencing the image by id and never holding the image
definition itself.

## Boundary with CriomOS-home

NixOS-level capabilities live here. Home Manager profile selection, user
packages, and desktop-owned configuration live in CriomOS-home. Cluster,
node, user, and deployment identity all enter through lojix-projected
inputs; CriomOS modules render those projected facts and never branch on
concrete cluster or node names. Swap and compressed-swap policy for a
node is authored as cluster data, projected through Horizon, and rendered
here into NixOS swap / zram options.

## What this repo does not define

- Sema, signal, or any application-layer record kind.
- The criome daemon, forge daemon, or any sema-ecosystem
  binary.
- The deploy orchestrator — that's `github:LiGoldragon/lojix`.

## Status

CANON. Active host platform.

## Cross-cutting context

- Workspace contract: lore's `AGENTS.md` (symlinked at `repos/lore/`).
- Project-wide architecture: criome's `ARCHITECTURE.md`.
- CriomOS membership in the broader workspace:
  workspace's `docs/workspace-manifest.md`.
