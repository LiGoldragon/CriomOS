# Distributed builds — deployed in production archive

Session 2026-04-27. The "TODO - broken" `distributedBuilds + buildMachines`
block in archive is no longer broken; ouranos-as-dispatcher → prom-as-builder
is live and verified end-to-end. Durable architectural docs landed in
[criomos-archive/docs/DISTRIBUTED_BUILDS.md](https://github.com/LiGoldragon/criomos-archive/blob/main/docs/DISTRIBUTED_BUILDS.md);
this report is the snapshot of *this session's* work and incidental
findings.

## Commits that landed

### criomos-archive
| Commit | What |
|---|---|
| ef07ed16 | Distributed-builds wiring: sshServe.{trusted,write,protocol} + buildMachines + knownHosts + drop nixBuilder user; mkBuilder gains publicHostKey + publicHostKeyLine; supportedFeatures += kvm; sshUser nixBuilder→nix-ssh |
| 761a3e3b | qwen3.5-27b moved to disabledModels (stale-drv workaround) |
| eb365a09 | mentci pin bumped (force-pushed commit) |
| 0114eaba | mentci-codium refs dropped (package gone post-rewrite) |
| 290764ea | mergeMentciMcp activation dropped (mcpSettings gone) |
| 3ba9b79e | maisiliym pin bumped (picks up prom precriads) |
| fec4eae9 | docs/DISTRIBUTED_BUILDS.md added |

### maisiliym/dev
| Commit | What |
|---|---|
| bedd3439 | Add prometheus's missing base-precriads (ssh host pubkey + nixPreCriome + nixSigningPublicKey) |

### Other repos (touched, but the substance moved into archive)
- horizon-rs `01e1a774` — BuilderConfig.public_host_key fields; turned out the new criomos work but production runs archive
- lojix-cli `ae341372`, `4d5ff0b4`, `bb8a6d2e`, etc. — flake outputHashes + pname fixes from the new-criomos detour
- CriomOS `b9143325` — same wiring in the new criomos's nix.nix (parallel to archive — useful when new criomos goes production)
- CriomOS-home `ef7a1756` — restored the AI CLIs (claude-code/codex) that the 2026-04-25 trim wrongly dropped

## End-to-end verification

```
nix build --max-jobs 0 --impure --expr \
  'let pkgs = import <nixpkgs> {}; in
   pkgs.runCommand "dist-test-N" {} "echo built > $out"'
```

Logged: `building '/nix/store/3r3v2kpm6...drv' on 'ssh-ng://nix-ssh@prometheus.maisiliym.criome'`. The dispatch happened.

## Bootstrap procedure for prom's signing key

One-time on prom:

```bash
mkdir -p /var/lib/nix-serve
nix-store --generate-binary-cache-key \
  prometheus.maisiliym.criome \
  /var/lib/nix-serve/nix-secret-key \
  /var/lib/nix-serve/nix-secret-key.pub
chmod 600 /var/lib/nix-serve/nix-secret-key
```

Pubkey: `prometheus.maisiliym.criome:vCjiTyT4+sVkjvASSKteq7RZ1/b8hploA7kliKnrpKk=`

The base64 portion plus the SSH host pubkey were added to maisiliym's
prom entry as `preCriomes.{ssh, nixPreCriome, nixSigningPublicKey}`.
This is what made `hasBasePrecriads = true` for prom, which made
`isBuilder = true`, which fired the new `nix.sshServe` wiring.

## Tech debt encountered (not addressed this session)

| Issue | Where | Status |
|---|---|---|
| Stale `Qwen3.5-27B-Q4_K_M.gguf.drv` in ouranos's nix-store | matches memory `project_prometheus_store_corruption` (454 disappeared paths) | Worked around by moving the model to `disabledModels`. Real fix: `nix-store --repair` or full re-instantiation. |
| Mentci force-pushed history | `LiGoldragon/Mentci` → `LiGoldragon/mentci` rename involved rewrite | Worked around (lock bump). Future force-pushes will require similar bumps. |
| `mentci-codium` package gone | post-rewrite mentci flake only exposes `nixfmt-tree-2.4.1` | Dropped from archive's homeModule/med + new home's profiles/med. Re-architecting if Li still wants a mentci codium variant. |
| `programs.claude-desktop.enable = true` in archive | landed earlier session, still in mkCriomOS/default.nix:55 | Not a regression today, just noted. |
| HM activations fail with `ca.desrt.dconf` | headless prom has no D-Bus session | Pre-existing. Activations are non-fatal. Real fix: gate dconf activation on `hasGraphicalSession` or skip on prom. |
| `headscale.service` activation fails on ouranos | post-deploy `auto-restart`/`exit-code` | Pre-existing config issue surfaced by the deploy. Doesn't block distributed-builds. |
| Stale `http://nix.prometheus.maisiliym.criome` substituter URL warning | some node has a `cacheUrls` reference to an HTTP cache that doesn't exist | Cosmetic warning, "disabled for 60s". Real fix: scrub the reference. |
| Prom `maxJobs = 1` in `/etc/nix/machines` | `node.nbOfBuildCores` projection produces 1 instead of 8/16 | Tunable in maisiliym's prom entry or in archive's `nix_concurrency` derivation. Heavy builds will only do 1 at a time on prom until fixed. |

## What this enables next

- Heavy CriomOS builds from ouranos auto-dispatch to prom (no manual `--builders` flag, no manual `nix copy`).
- ouranos builds the closure but the actual derivation realisation happens on prom's 32 cores.
- Models / kernel / chromium / LLVM all get `big-parallel` — they offload too.
- The "build prom on prom" pattern (used to bootstrap this session) is no longer needed for incremental work.

## Open beads relevant

None opened or closed this session. The CriomOS-home `home-f68` (verify
verbatim home modules) remains open and orthogonal — about the new
criomos's home, not archive's.
