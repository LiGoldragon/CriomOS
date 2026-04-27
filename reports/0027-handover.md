# Handover — CriomOS ecosystem session

Comprehensive picker-up document for the work that landed across the
2026-04-25 → 2026-04-27 sessions. Anyone resuming cold should read
this report first, then follow the per-area pointers into durable
docs.

## What this session accomplished

The headline win: **distributed builds work in production archive**
— ouranos dispatches heavy derivations to prom over `ssh-ng://nix-ssh`,
verified end-to-end with a forced-remote build that logged
`building '/nix/store/...drv' on 'ssh-ng://nix-ssh@prometheus.maisiliym.criome'`.

Surrounding work (loosely chronological):

1. New CriomOS module wiring (parallel to archive — ready when the
   new criomos becomes production).
2. Two repo extractions: `CriomOS-pkgs` (was in-tree pkgs-flake) and
   `CriomOS-lib` (was in-tree lib helpers). Both extracted because
   in-tree path-input flakes invalidate the eval cache on every
   parent-flake source edit (verified empirically).
3. `horizon-rs` schema extensions: `BuilderConfig.public_host_key{,_line}`,
   `ssh_user = "nix-ssh"`, `supportedFeatures` includes `kvm`. Plus
   the user.size capping fix (port regression — `User::project` now
   caps user.size to viewpoint_node.size, mirroring archive's
   `lowestOf [inputUser.size node.size]`).
4. `lojix-cli` modernization: `tokio::process` + `process-wrap`
   (kill-cascade), `BuildLocation::Remote` stub (no impl yet, comment
   points at `openssh` crate plan), Cargo.lock vendor hashes via
   `nix flake metadata` (clean approach).
5. Closure-shrinkage cleanup leaked into a real regression: the
   2026-04-25 trim wrongly dropped Li's daily AI tools (claude-code,
   codex). Restored in CriomOS-home (with `llm-agents` + `codex-cli`
   as flake inputs again).
6. Mentci/cosmetic drift in archive — three forced-pushed/missing
   refs across `mentci-codium`, `mcpSettings`, force-pushed Mentci
   commit. Worked around by drops + lock bump.
7. Multiple AGENTS.md tightenings: report hygiene rule
   (don't restate-to-refute), report rollover at soft cap,
   reports-not-durable-documentation principle.
8. README rewrites: CriomOS's was stale (described the tombstoned
   `crioZones.<cluster>.<node>.*` pattern); now matches current code.

## Per-area files to read

### Distributed builds (the production deploy)

**Start here**:
[`criomos-archive/docs/DISTRIBUTED_BUILDS.md`](https://github.com/LiGoldragon/criomos-archive/blob/main/docs/DISTRIBUTED_BUILDS.md)
— durable architecture, host-key-as-user-key trick, predicate gates,
five common breakages with causes, deploy-verification commands.

**Then the wiring**:
- [`criomos-archive/nix/mkCriomOS/nix.nix`](https://github.com/LiGoldragon/criomos-archive/blob/main/nix/mkCriomOS/nix.nix)
  — receiver branch (`nix.sshServe.{enable=isBuilder, write, trusted, protocol}`)
  + dispatcher branch (`distributedBuilds + buildMachines + programs.ssh.knownHosts`).
- [`criomos-archive/nix/mkCrioZones/mkHorizonModule.nix`](https://github.com/LiGoldragon/criomos-archive/blob/main/nix/mkCrioZones/mkHorizonModule.nix)
  — `mkBuilder` (BuilderConfig), `isBuilder`/`isDispatcher` predicates,
  `hasBasePrecriads = hasNixPreCriad && hasYggPrecriad && hasSshPrecriad`.

**Per-node data**:
- [`maisiliym/datom.nix`](https://github.com/LiGoldragon/maisiliym/blob/dev/datom.nix)
  — node `preCriomes` blocks. **Prom's block** is what we updated this
  session: `ssh`, `nixPreCriome`, `nixSigningPublicKey` populated
  alongside the existing `yggdrasil` sub-block.

### New CriomOS (parallel to archive, not deployed)

**Start**:
- [`CriomOS/AGENTS.md`](AGENTS.md) — hard rules + report-corpus rules.
- [`CriomOS/ARCHITECTURE.md`](ARCHITECTURE.md) — repo role.
- [`CriomOS/README.md`](README.md) — current architecture (3-flake +
  lojix-cli orchestration). Was rewritten this session — old version
  described the tombstoned consumer-pull pattern.

**Wiring**:
- [`CriomOS/flake.nix`](flake.nix) — inputs: criomos-lib, criomos-pkgs,
  criomos-home, brightness-ctl, clavifaber, system, pkgs, horizon
  (last three default to stubs, lojix-cli overrides).
- [`CriomOS/modules/nixos/criomos.nix`](modules/nixos/criomos.nix) — top aggregate.
- [`CriomOS/modules/nixos/nix.nix`](modules/nixos/nix.nix) — distributed-builds
  wiring (parallel to archive's). Uses horizon-rs's `builderConfigs`
  + `dispatchersSshPubKeys` + `isBuilder`/`isDispatcher` (camelCase).
- [`CriomOS/modules/nixos/network/default.nix`](modules/nixos/network/default.nix) —
  `networking.hosts` generation from `horizon.exNodes` (will resolve
  `*.goldragon.criome` once new criomos is deployed; currently
  ouranos has `*.maisiliym.criome` from archive).

### CriomOS-home

**Inputs**:
- [`CriomOS-home/flake.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/flake.nix)
  — niri-flake, noctalia, stylix, mentci-tools, criomos-lib,
  **`llm-agents` + `codex-cli`** (re-added this session for AI CLI
  restoration). Wrapper at `outputs.homeModules.default` injects
  `_module.args.{inputs, criomos-lib}` via `lib.mkForce`.

**Profiles** (consumed via `user.size.atLeast{Min,Med,Large,Max}`):
- [`modules/home/profiles/min/default.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/modules/home/profiles/min/default.nix)
  — base. `AIPackages = [ gemini-cli, llm-agents.claude-code,
  codex-cli.default, opencode, llama-cpp ]`.
- [`modules/home/profiles/med/default.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/modules/home/profiles/med/default.nix)
  — medium. `mentci-codium` tombstone-comments cleaned this session.
- [`modules/home/profiles/max/default.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/modules/home/profiles/max/default.nix)
  — heavy. gimp/krita/calibre/inkscape gated by `user.size.atLeastMax`
  (which is now correctly capped by node.size after horizon-rs fix).
- [`modules/home/neovim/neovim/default.nix`](https://github.com/LiGoldragon/CriomOS-home/blob/main/modules/home/neovim/neovim/default.nix)
  — bare-min (was 346 lines of plugins, now 7 — Li doesn't use neovim).

### horizon-rs

- [`lib/src/node.rs`](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/node.rs)
  — `BuilderConfig` (extended this session: `public_host_key`,
  `public_host_key_line`, `ssh_user = "nix-ssh"`, `supportedFeatures`
  + `kvm`); `is_builder` / `is_dispatcher` derivations.
- [`lib/src/user.rs`](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/user.rs)
  — `UserProjection.viewpoint_node_size` (added); `User::project`
  caps `size = self.size.floor(ctx.viewpoint_node_size).ladder()`.
- [`lib/src/proposal.rs`](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/proposal.rs)
  — `NodePubKeys`, `UserProposal`, etc.
- [`lib/src/pub_key.rs`](https://github.com/LiGoldragon/horizon-rs/blob/main/lib/src/pub_key.rs)
  — `SshPubKey` / `SshPubKeyLine` distinction.

### lojix-cli

- [`ARCHITECTURE.md`](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md)
  — "Build orchestration model" section (durable: subprocess shape,
  daemon-vs-client parallelism reasoning, build-FOR vs build-ON
  remote distinction).
- [`src/build.rs`](https://github.com/LiGoldragon/lojix-cli/blob/main/src/build.rs)
  — `NixInvocation::run` (tokio::process + process-wrap +
  KillOnDrop + ProcessGroup); `BuildLocation::Remote` stub.
- [`flake.nix`](https://github.com/LiGoldragon/lojix-cli/blob/main/flake.nix)
  — vendor `outputHashes` (3 git deps: horizon-rs, nota-serde,
  nota-serde-core). When deps bump, refresh via:
  `nix flake metadata "git+https://github.com/...?rev=..." --json | jq .locked.narHash`
  per dep, sed-patch.

### CriomOS-pkgs

- [`flake.nix`](https://github.com/LiGoldragon/CriomOS-pkgs/blob/main/flake.nix)
  — instantiates nixpkgs with `config.allowUnfree = true` and the
  **openldap doCheck=false overlay** (workaround for
  `test017-syncreplication-refresh` flakiness — known nixpkgs CI
  issue, NixOS/nixpkgs#440594 closed-as-not-planned).

### CriomOS-lib

- [`lib/default.nix`](https://github.com/LiGoldragon/CriomOS-lib/blob/main/lib/default.nix)
  — `importJSON`, `mkJsonMerge`. Both consumed via flake input by
  CriomOS and CriomOS-home.
- [`data/largeAI/llm.json`](https://github.com/LiGoldragon/CriomOS-lib/blob/main/data/largeAI/llm.json)
  — accessed by `CriomOS/modules/nixos/llm.nix` via
  `inputs.criomos-lib + "/data/largeAI/llm.json"`.

### maisiliym (production cluster proposal)

- [`datom.nix`](https://github.com/LiGoldragon/maisiliym/blob/dev/datom.nix)
  — node spec block per node + cluster-level trust. **prometheus
  preCriomes** populated this session with `ssh`, `nixPreCriome`,
  `nixSigningPublicKey`, `yggdrasil`. The full set of three keys
  is what `hasBasePrecriads` requires for a node to be `isBuilder`.

### goldragon (new criomos cluster proposal)

- [`datom.nota`](https://github.com/LiGoldragon/goldragon/blob/main/datom.nota)
  — **on v2 nota syntax** (`[name]` for strings, `<...>` for lists).
  The current `nota-serde-core` (rev `0a7a047b`, "v3 delimiter set")
  REJECTS `<...>` — they're now reserved for future comparison
  operators. **This blocks any nota-serde-driven eval against goldragon
  until the file is migrated to v3 syntax.** See "Open issues" below.

## Production deploys (today)

| Node | What ran | New toplevel |
|---|---|---|
| prometheus | `nix build github:LiGoldragon/criomos-archive#crioZones.maisiliym.prometheus.fullOs` then `switch-to-configuration switch` | `/nix/store/hjw8i6fhr11yclclr9spsjdrdkkr55cq-nixos-system-prometheus-...` |
| ouranos | Build done on prom, `nix copy --from ssh-ng://prom`, then `switch-to-configuration switch` | `/nix/store/511f6l5s1pw8b7v2zaaxzx23n3q6fbh7-nixos-system-ouranos-...` |

End-to-end test: dispatch a `runCommand` from ouranos with
`--max-jobs 0` (forces remote). Got
`building '...drv' on 'ssh-ng://nix-ssh@prometheus.maisiliym.criome'`.

## Open issues / partially done / unaddressed

### Production (archive)

- **Prom's `nbOfBuildCores` projects to `maxJobs = 1` in `/etc/nix/machines`** — the dispatcher will only ask prom to run ONE derivation in parallel until fixed. Likely either a maisiliym datom field needs setting (e.g. `nbOfBuildCores = 16`) or archive's projection is bugged. Deploy still works, just not at full prom capacity.
- **Stale qwen3.5-27b model** moved to `disabledModels` in `data/config/largeAI/llm.json`. Real fix: `nix-store --repair` or full re-instantiation against ouranos's stale `system-units.drv` that still references `gpn4v2mw...Qwen3.5-27B-Q4_K_M.gguf.drv`. Memory: `project_prometheus_store_corruption.md` (454 disappeared paths).
- **HM activation failures on prom** — `home-manager-{li,maikro,bird}.service` exit 1 on `ca.desrt.dconf` (no D-Bus session on headless server). Pre-existing. Real fix: gate `dconf` activation on `hasGraphicalSession` or skip on headless. Cosmetic — system functional.
- **`headscale.service` keeps auto-restarting on ouranos** — `code=exited, status=1/FAILURE` after the deploy. Pre-existing config issue surfaced by the activation. Probably needs the headscale config file regenerated or a deps issue.
- **Stale `http://nix.prometheus.maisiliym.criome` substituter URL** logs "disabling binary cache for 60s" warning. Some node has a `cacheUrls` reference to an HTTP cache URL that doesn't resolve. Cosmetic, but noisy.
- **`programs.claude-desktop.enable = true` in `archive/nix/mkCriomOS/default.nix:55`** — still there. Heavy Electron app; Li uses claude-code (CLI) per session — claude-desktop may be redundant. Not a regression today, just noted.
- **Mentci force-push recovery** — current `mentci` flake input pinned at `LiGoldragon/mentci` HEAD. If that history rewrites again, archive's pin breaks again. No durable safeguard.

### New criomos

- **`goldragon/datom.nota` is v2 syntax**, current `nota-serde-core` rejects it. Two paths: (a) migrate datom.nota to v3 (`[ ]` for sequences, `" "` for strings — affects every line), (b) pin nota-serde-core back to a v2-accepting rev. Without resolution, any lojix-cli eval against goldragon fails with "reserved token '<'".
- **`home-f68` (CriomOS-home P1 bead)**: "Adapt verbatim home modules to consume new horizon schema". Open. Walking the home modules to confirm they use `user.size.atLeastMed` etc (camelCase), not the old `Mg.is.med` shape. The session's empirical eval suggests it works (build succeeded), but a focused audit hasn't happened.
- **balboa (Arm64) not in any production-deploy flow** — needs aarch64 builder OR defer indefinitely. balboa runs on rock64 SD card, redeploy is rare. Memory: rock64 ARM Cortex-A53.
- **Hostname resolution drift** — once new criomos deploys to a node, `*.goldragon.criome` will replace `*.maisiliym.criome` in `/etc/hosts` (via `network/default.nix`). Until then, ouranos's /etc/hosts has only `maisiliym` entries — `prometheus.goldragon.criome` doesn't resolve.

### lojix-cli

- **Steps 3 + 4 of the orchestration migration plan are deferred**:
  - **Step 3**: per-target `NodeBuildActor` ractor + `JoinSet` for parallel multi-node builds. Defer rationale: nix-daemon already parallelises locally via `max-jobs`; client-side parallelism is UX-only (single output stream, unified Ctrl-C). Trigger to wire: `lojix build --cluster goldragon` one-shot dashboard.
  - **Step 4**: `indicatif::MultiProgress` + `tracing-indicatif`. Conditional on Step 3.
  - Durable plan in [`lojix-cli/ARCHITECTURE.md`](https://github.com/LiGoldragon/lojix-cli/blob/main/ARCHITECTURE.md) §"Build orchestration model".
- **`BuildLocation::Remote` stub** — landed but unimplemented. Pending the lojix daemon (no implementation, just an extension point with `Error::NotImplemented` + comments pointing at `openssh::Session::command()`).

### Other open beads

- **`CriomOS-1ey` (P2 epic)** — security/architectural fixes from criomos-archive AUDIT-2026-04-17 (SEC-1 LLM key on cmdline, SEC-2 SAE password, SEC-3 wireguard keys, MOD-1 metal split, MOD-2 firmware contradiction, MOD-3 nixosModules/vmModules dedup). Per Li, "fix later".
- **`CriomOS-bb5` (P2)** — criomos-cfg side-repo (3-way merge for managed-mutable config files; replaces broken shallow `mkJsonMerge`). Design: `reports/0011`. Deferred.
- **`CriomOS-4xw` (P3)** — criomos-hw-scan Rust CLI. Design: `reports/0014`. Deferred.
- **`CriomOS-og4` (P3)** — fate of `docs/ROADMAP.md` (rewrite vs delete). Deferred.

### Memories worth knowing

The bd memory store has accumulated a dozen or so insights across sessions. Most relevant for picking up:

- **`feedback_no_store_paths`** — never paste raw store paths; use `$(nix build --print-out-paths)` inline or `readlink result`.
- **`feedback_no_pkill_no_cpf`** — process management: don't `pkill -f` in scripts; prefer process-groups (e.g. process-wrap's KillOnDrop). Lojix-cli already does this.
- **`feedback_no_sudo_no_root`** — for root operations, use `ssh root@localhost`, never sudo.
- **`feedback_no_live_hm_activate`** — never live-activate HM with compositor/input changes.
- **`feedback_jj_no_editor`** — always pass `-m` / non-interactive flags; never trigger editor.
- **`reference_3flake_arch`** — system + pkgs + horizon as independently cacheable axes.
- **The pgrep-regex orphan issue** from this session: `pgrep -af "lojix\|nix"` doesn't alternate (POSIX BRE vs ERE confusion), use simpler patterns or grep -E. Lost an hour debugging "missing processes" that were actually still alive.

## Trigger to revisit each deferred item

| Trigger | What to revisit |
|---|---|
| Sustained throughput ceiling on prom-as-builder | Fix `nbOfBuildCores → maxJobs` projection so prom builds 16 in parallel |
| Need to deploy or eval new criomos against goldragon | Migrate `goldragon/datom.nota` to v3 (`<>` → `[ ]`, `[name]` → `"name"`) |
| Want one-shot `lojix build --cluster goldragon` UX | Step 3 (per-target ractor) + Step 4 (multi-progress) |
| Lojix daemon lands | Wire openssh in lojix-cli's `BuildLocation::Remote` branch |
| New criomos production cutover | Walk `home-f68`, build+deploy each node from new criomos, retire archive |
| Prom throughput suspected wrong | Check `/etc/nix/machines` line for prom's maxJobs vs prom's actual cores |
| New builder added to maisiliym | Generate signing key on the new node, register `preCriomes.{ssh, nixPreCriome, nixSigningPublicKey}` per the bootstrap procedure in `criomos-archive/docs/DISTRIBUTED_BUILDS.md` |
