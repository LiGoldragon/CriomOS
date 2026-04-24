# 2026-04-24 — architecture deep audit

Synthesis of four parallel deep audits: horizon-rs schema vs CriomOS
module needs, lojix v1 production-readiness, per-module rewrite scope
(CriomOS-52j), and cross-cutting hygiene + data quality.

This is the canonical audit at the moment the 3-flake architecture
landed and the first end-to-end build succeeded. Beads filed at the
end; open questions surfaced for your call.

## TL;DR

- **horizon-rs schema is 99% complete** for what the 33 CriomOS
  modules will need. One genuine bug (`normalize.nix:42` reads
  `.ssh`, schema emits `.sshPubKeyLine`); zero schema additions
  required.
- **lojix v1 is sound architecturally, fragile in practice.** Three
  CRITICAL gaps: subprocess output is buffered (silent multi-hour
  builds), artifact materialization isn't atomic (corrupted dir on
  kill), no concurrent-deploy safety. Plus tarball publish missing
  (lojix-d56) and Switch/Boot/Test don't check for root.
- **CriomOS-52j module rewrite is mostly mechanical.** 33 modules:
  1 wired, 20 mechanical, 3 mech+small new code, 3 heavy (but
  mechanical at heart), 6 to delete, 6 unchanged. ~10–12 engineering
  hours total once `nix.nix` design questions are answered.
- **Two real syntax errors** lurking in `checks/librist.nix` (will
  reject `nix flake check`).
- **goldragon data has two known holes**: `prometheus` lacks an
  ssh host key, `maikro` has empty `pubKeys` post-xerxes-removal.
  Both already tracked.

## 1. horizon-rs schema vs module needs

**Verdict: ready, modulo one rename.**

Of 35 distinct `horizon.X.Y.Z` access patterns across the 33 modules,
33 are satisfied by horizon-rs's flat shape (after `.methods.X` →
`.X` flattening). The 1 broken access:

- [normalize.nix:42](../modules/nixos/normalize.nix#L42) reads
  `node.ssh` (legacy name). horizon-rs emits `node.sshPubKeyLine`.
  One-character fix during the rewrite of normalize.nix.

The other apparent oddity (`Node.builderConfigs` exists but no
module currently uses it) is fine — it's a viewpoint-only field
populated for future use. No schema additions required.

Viewpoint-only fields (`Option<T>` on `horizon.node`, `None` on
ex_nodes) are correctly typed and serialized: `io`, `useColemak`,
`computerIs`, `builderConfigs`, `cacheUrls`, `exNodesSshPubKeys`,
`dispatchersSshPubKeys`, `adminSshPubKeys`,
`wireguardUntrustedProxies`. Modules that read these need
`horizon.node.X` (Some, populated).

## 2. lojix v1 — sound, but production-fragile

**Verdict: works for the kriom owner today; would lose a finger in a
real fleet.**

Architecture matches the design report perfectly. SystemDir was
correctly added alongside HorizonDir (the user's correction);
`--override-input system` is wired. All 5 actors materialized.
Style: 1 minor violation (`unwrap_call` is a free fn in
[deploy.rs:89](../repos/lojix/src/deploy.rs#L89); should be a
method on `DeployState`).

### Critical fragilities

- **No subprocess streaming.** [build.rs:42](../repos/lojix/src/build.rs#L42)
  uses `cmd.output()` which buffers stdout/stderr until exit. A
  20-minute `nix build` shows nothing on the operator's terminal
  until it finishes. Should switch to `tokio::process::Command`
  with line-buffered streaming. (P0; blocks any real Build/Switch
  workflow.)
- **Materialization not atomic.** [artifact.rs:32](../repos/lojix/src/artifact.rs#L32)
  writes `horizon.json` then `flake.nix`. `kill -9` between writes
  leaves a corrupted dir; next run's `nix hash path` fails. Fix:
  write to `<dir>.tmp/`, atomically rename, or use `tempfile::TempDir`
  + final `rename`.
- **Concurrent deploys race.** Two `lojix` processes targeting the
  same (cluster, node) will collide on `~/.cache/lojix/horizon/<c>/<n>/`.
  Need flock or per-pid temp + atomic rename.
- **Root not checked for Switch/Boot/Test.** [build.rs:71-83](../repos/lojix/src/build.rs#L71-L83)
  invokes `nixos-rebuild switch` without checking effective uid.
  User runs as themselves, gets confusing permission error from
  deep in nix evaluation. Should fail fast with "lojix switch
  requires root: try sudo".
- **Exit-code masking.** `out.status.code().unwrap_or(-1)` collapses
  signal kills (None) and exit 255 to the same `-1`. Can't tell OOM
  from genuine failure.

### Missing-from-design

- **Tarball publish** (`lojix-d56` P1) — entirely absent. Today both
  overrides are `path:` URIs, so this is local-only-by-default.
- **`--no-publish` flag** (`lojix-1ke` P1) — the design's
  iteration-mode escape hatch. Currently moot (publish doesn't
  exist), but the flag will need to land alongside the publish
  feature.
- **No remote-deploy plumbing.** No `--target-host` /
  `--build-host` forwarded to nixos-rebuild. lojix can't deploy
  one machine from another — only locally.
- **No SSH credential routing.** Cluster has (user, node, key)
  triples in goldragon. lojix has no logic to pick the right key
  for `ssh root@<target>`.

### Test coverage

Two integration tests (`tests/eval.rs`); both happy-path. Nothing
exercises:

- error paths (missing nota, unparseable nota, missing node,
  HOME unset, unwritable cache, nix timeout, nix exit failure)
- the other 5 nodes (only tiger; balboa/klio/ouranos/prometheus/zeus
  untested)
- the other 4 actions (Build/Boot/Switch/Test)
- concurrency, signal handling, cleanup

## 3. CriomOS-52j — module rewrite scope

**Verdict: ~10–12 hours of mostly mechanical work, after one design
session for nix.nix.**

Per-module breakdown (full table in agent report; summarized here):

| Class | Count | Examples |
|---|---|---|
| Wired-and-working | 1 | [disks/preinstalled.nix](../modules/nixos/disks/preinstalled.nix) |
| Mechanical (drop ghost args, flatten `.methods`) | 20 | normalize, network/{wireguard,unbound,yggdrasil,…}, users, userHomes, etc. |
| Mechanical + small new code | 3 | nix.nix (needs design), network/trust-dns.nix |
| Heavy (mechanical at heart, high density) | 2 | metal/default.nix (~29 `.methods` refs), edge/default.nix (~15) |
| Delete (superseded by horizon-rs) | 6 | zones/{default,horizonOptions,mkHorizonModule}.nix, sphere/{default,clustersModule,speciesModule}.nix |
| Unchanged | 6 | constants, complex, llm, router/yggdrasil, network/tailscale, disks/pod |

### Phased execution order (least-risk first)

1. **Phase 1 — confirmation pass (5 min):** the 6 unchanged files;
   no-op verification.
2. **Phase 2 — single-`.methods`-flatten files (30 min):**
   network/{networkd,wifi-eap,yggdrasil,nordvpn},
   router/wifi-pki, disks/liveiso. Pure search-and-replace.
3. **Phase 3 — multi-`.methods` files (1.5 h):** users.nix,
   userHomes.nix (drop `world` from extraSpecialArgs),
   network/{unbound,default,wireguard,trust-dns}.
4. **Phase 4 — small-new-code (1 h after design):** normalize.nix
   (drop world+pkdjz; replace `pkdjz.exportJSON` with
   `pkgs.writeText (builtins.toJSON …)`; fix the `.ssh` →
   `.sshPubKeyLine` rename).
5. **Phase 5 — design-blocked (variable):** nix.nix. See Open
   Questions below; needs answers before code lands.
6. **Phase 6 — heavy-mechanical (4–5 h):** metal/default.nix,
   edge/default.nix. High `.methods` density; recommend a sed
   script + before/after grep verification.
7. **Phase 7 — delete (5 min):** zones/, sphere/. Verify nothing
   imports them first.
8. **Phase 8 — wire criomos.nix imports (5 min):** uncomment as
   modules land.

## 4. Cross-cutting findings

### Verified bugs (not just style)

- **`checks/librist.nix:33`** — `"rist:$receiverIpAndPort"` —
  unescaped `$`; should be `\$`.
- **`checks/librist.nix:45`** — `writeScriptBin ""` — empty
  derivation name; nix flake check rejects.
- **`normalize.nix:42`** — `node.ssh` (does not exist on the new
  Node shape; should be `node.sshPubKeyLine`).

### Goldragon data holes (already tracked)

- `prometheus` has no SSH host pubkey ([gold-alz](../repos/goldragon/.beads/) — closed prematurely; has been added but yggdrasil pubkey still TBD per gold-8gn)
- `maikro` user has empty `pubKeys` after xerxes removal — currently
  parses fine (BTreeMap default), but the user has no SSH access
  anywhere. May want to either drop maikro or fill in.
- `xerxes` `linkLocalIps` was removed entirely along with the node;
  bead `gold-jsm` (closed) was about iface verification — now moot.

### Memory file gaps

The newer architectural decisions aren't reflected in
`~/.claude/projects/-home-li-git-CriomOS/memory/`. Future agents
opening cold won't easily see:

- The 3-flake architecture (system + pkgs + horizon as separate
  flake inputs).
- lojix as the orchestrator with the ractor actor pipeline.
- The cache property (same content → same narHash → cached eval).
- horizon-rs's flat-fields (no `.methods.` nesting).

These should be added as `reference_*.md` memories pointing at the
relevant report files in `reports/`.

### Hygiene

- The `llm-agents` and `claude-for-linux` ghost references were
  cleaned earlier; the audit's stale flags can be ignored.
- No remaining `maisiliym` mentions in CriomOS code.
- jj op-store still has historical references to those names — that's
  immutable history; not a concern.

## 5. Critical path to a real deployable single node

In dependency order, smallest-first:

1. **Fix `normalize.nix:42` rename** (5 min, included in Phase 4).
2. **Fix `checks/librist.nix` syntax** (10 min, separate bead).
3. **Phase 1–4 module rewrites** (~3 hours, mechanical).
4. **Answer the nix.nix design questions** (one design session).
5. **Phase 5 (nix.nix), then 6–8** (~5 hours mechanical).
6. **Verify `lojix build` against ouranos produces a buildable
   nixosConfiguration** (not just drvPath) — this is the first
   true checkpoint that the deploy actually works.
7. **Then lojix Switch with root + remote-host plumbing** — separate
   beads (Critical fragilities #4 above).

After that, real deploy works locally on ouranos. Cluster deploy
(other nodes) waits on `lojix-d56` (publish) + `--target-host`.

## 6. Beads filed (this report)

See `bd list --status open` per repo. New beads created today
(post-report; will be filed and listed inline once `bd create` runs):

**lojix (10 new):**
- `lojix-auy` P0 — stream subprocess stdout/stderr
- `lojix-cv1` P0 — atomic artifact materialization (write-temp + rename)
- `lojix-zs7` P1 — concurrent-deploy safety (flock per cache subdir)
- `lojix-eop` P1 — root check for Switch/Boot/Test
- `lojix-hcl` P1 — exit-code clarity (distinguish signal kill)
- `lojix-bf8` P1 — error-path test coverage
- `lojix-njq` P2 — all-actions tests (Build/Boot/Switch/Test)
- `lojix-nxq` P2 — `--target-host` / `--build-host` plumbing
- `lojix-0po` P2 — `--rpc-timeout-secs` flag (currently 900s hardcoded)
- `lojix-8yi` P3 — refactor `unwrap_call` to method (style canon)

**CriomOS (9 new, all children of `CriomOS-52j`):**
- `CriomOS-8ae` P0 — fix `checks/librist.nix` syntax errors
- `CriomOS-l2g` P0 — Phase 1 (verify 6 unchanged modules)
- `CriomOS-mme` P0 — Phase 2 (single-`.methods` flattens, 6 modules)
- `CriomOS-3ha` P0 — Phase 3 (multi-`.methods` + drop ghost args)
- `CriomOS-16v` P0 — Phase 4 (normalize.nix + `.ssh` rename)
- `CriomOS-a4s` P1 — Phase 5 nix.nix (BLOCKED on design Q1–Q4)
- `CriomOS-dfk` P1 — Phase 6 (metal + edge heavy mechanical)
- `CriomOS-012` P1 — Phase 7 (delete zones/, sphere/)
- `CriomOS-gqq` P1 — Phase 8 (wire criomos.nix imports)

## 7. Open questions for you

These genuinely block the rewrite or affect architectural choices
beyond what I should decide alone.

1. **`world.skrips.root`** in [nix.nix:104](../modules/nixos/nix.nix#L104).
   What is `skrips.root` semantically? The original archive
   mapped through a `criome/skrips` flake input that exposed
   shell-script tooling. Two paths:
   - (a) Inline the relevant scripts directly into a CriomOS
     `packages/` derivation.
   - (b) Add `skrips` as a flake input and consume it directly
     (no `world.` indirection).
   Preference?

2. **`world.pkdjz.flake-registry`** — same file. The archive used
   pkdjz to expose the nixpkgs flake-registry data. In the new
   design, where should this live?
   - (a) Add a `flake-registry` input to CriomOS.
   - (b) Inline a static registry attrset in `constants.nix`.
   - (c) Drop the registry override entirely.

3. **`hob.nixpkgs.{ref, rev}`** — same file again. The old code
   pinned nixpkgs by reading `hob`'s metadata. Today CriomOS owns
   the nixpkgs pin via flake.lock. Confirm: pull `ref`/`rev` from
   `inputs.nixpkgs.{rev, sourceInfo}` or just hardcode the channel
   name?

4. **`pkdjz.exportJSON`** — used in 2 places. Replace with
   `pkgs.writeText name (builtins.toJSON attrs)` everywhere?
   (Suggested yes — it's the canonical Nix idiom.)

5. **maikro user** — empty pubKeys after xerxes removal. Drop the
   user from goldragon, or leave with empty pubKeys (currently
   valid — they just have no SSH access)?

6. **Subprocess output streaming in lojix** — switch to
   `tokio::process::Command` now (P0 per the audit), or accept
   the buffered behavior until you actually hit a long build?
   It's small work (~30 min) but worth knowing your priority.

7. **`lojix switch` authentication model** — when `lojix switch
   --node tiger` runs from ouranos, how should it authenticate?
   - (a) Assume the operator already ssh-agent-forwarded their
     cluster key.
   - (b) lojix reads admin SSH keys from horizon.node.adminSshPubKeys
     and uses the matching private key from a known location.
   - (c) Out of scope for v1; document and ship local-only.
   Preference?

8. **Memory updates** — should I add `reference_3flake_arch.md`,
   `reference_lojix_orchestrator.md`, `reference_horizon_flat_shape.md`
   pointing at the relevant `reports/` files? (Suggested yes; future
   agents will cold-open and need to find these.)

## 8. What an agent picking up tomorrow should do

If the open questions above are answered: file the bead set listed
in §6 (or run `bd create` per below), then start at Phase 1 of the
module rewrite (5 min). Phase 2–4 cover ~3 hours of mechanical
work. nix.nix unblocks once Q1–Q4 are answered.

If the open questions are not answered: ask. Don't guess.
