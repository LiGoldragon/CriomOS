# CriomOS — Roadmap

Porting order (checklist form of the design essay). CriomOS is
network-neutral; CriomOS-home owns the home profile.

## Phase 0 — scaffold

- [x] `flake.nix` — blueprint + custom `crioZones` output
- [x] `crioZones.nix` — shape documented, empty
- [x] `devshell.nix`, `formatter.nix`
- [x] `lib/default.nix` — criomos-lib namespace + `mkHorizon` stub
- [x] `modules/nixos/criomos.nix` — empty aggregate
- [x] `docs/{ROADMAP,HORIZON}.md`, `AGENTS.md`, `README.md`

## Phase 1 — horizon-check (Rust, lives in `horizon-rs`)

- [ ] Port `Cluster` / `Node` / `User` / `PreCriomes` / `Machine` / `Io` types
      from `mkCrioSphere/clustersModule.nix`.
- [ ] Port method DAG from `mkCrioZones/mkHorizonModule.nix` — see
      `docs/HORIZON.md` for the one-to-one table.
- [ ] CLI: `horizon-check --cluster X --node Y < datom.json > horizon.json`.
- [ ] Golden-file tests against current legacy-CriomOS eval for every live
      maisiliym node.
- [ ] Nix wrapper: derivation whose output feeds `lib.mkHorizon` via IFD.
- [ ] Wire `lib/default.nix :: mkHorizon`.

## Phase 2 — first ported NixOS module + first crioZone

Lowest-coupling first.

- [ ] Port `normalize.nix`, `nix.nix`, `complex.nix`, `users.nix`.
- [ ] Port `network/unbound.nix`, `network/yggdrasil.nix`.
- [ ] Port `disks/preinstalled.nix`.
- [ ] Wire `crioZones.nix` to produce `os` + `fullOs` from an enriched horizon.
- [ ] Deploy-test `crioZones.maisiliym.tiger.os` (screened edge node).

## Phase 3 — rest of NixOS modules

- [ ] `metal/` split per audit MOD-1 (firmware, power, thinkpad, gpu).
- [ ] `edge.nix`, `router/`, `llm.nix`.
- [ ] `network/{nordvpn,wireguard,wifi-eap,networkd,tailscale,headscale,trust-dns}.nix`.
- [ ] `disks/{pod,liveiso}.nix`.
- [ ] Fix SEC-1/2/3 during the port (cmdline secrets, hardcoded SAE password, keys via env).

## Phase 4 — CriomOS-home (separate repo)

Tracked in `CriomOS-home`'s own ROADMAP.md. Blocking dependencies on this repo:

- [ ] CriomOS consumes `inputs.criomos-home.homeModules.default` in
      `crioZones.<cluster>.<node>.home.<user>`.

## Phase 5 — side-repo splits

- [ ] `github:LiGoldragon/clavifaber` — move `src/clavifaber/` out of legacy
      CriomOS, consume as input.
- [ ] `github:LiGoldragon/CriomOS-emacs` — replaces `pkdjz/mkEmacs`. Consumed by
      CriomOS-home, not by CriomOS directly.
- [ ] *(optional)* `github:LiGoldragon/criomos-brightness` — move brightness-ctl.

## Phase 6 — cutover

- [ ] Point `maisiliym` docs / deploy flows at CriomOS.
- [ ] Every host on CriomOS for ≥ 14 days.
- [ ] Archive legacy `github:LiGoldragon/CriomOS`.

## Open design questions

- **Cluster discovery signature.** `discoverClusters` in `lib/default.nix`
  filters inputs by `? NodeProposal`. Works today; revisit if a cluster
  proposal's shape grows richer.
- **capnp:** keep concept files, delete, or replace with schema auto-derived
  from horizon-rs's Rust types? Leaning delete.
