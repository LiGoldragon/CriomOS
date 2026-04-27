# Distributed builds — setup research

Trigger: Li wants prom as remote builder for ouranos. Archive had
the config commented as "TODO - broken" ([archive
nix/mkCriomOS/nix.nix:163-164](repos/criomos-archive/nix/mkCriomOS/nix.nix#L163)).
Don't blindly uncomment — investigate first, then write the right
config for new criomos.

## Verdict

The native `nix.buildMachines` + `nix.sshServe` mechanism is still
the right answer in April 2026 for the two-node homelab case.
Modern alternatives (buildbot-nix, Hercules CI, nixbuild.net,
nix-snapshotter) solve different problems (CI orchestration,
hosted build farms, container shipping) — not laptop-offloads-to-
server. The native path stays the simplest and best-maintained.

Use the **dispatcher's host key as the daemon's SSH identity**
(`/etc/ssh/ssh_host_ed25519_key`). This is the "host-key-as-user-
key" trick: sidesteps having to provision a user key for root
declaratively (NixOS doesn't ship one). The keypair already exists
on every NixOS box (sshd auto-generates), it's mode 600 root-owned,
and the dispatcher's pubkey is the *consumer-side* declarative
input on the builder's `nix.sshServe.keys`.

Yggdrasil's encryption is redundant with SSH but unavoidable: nix's
build-dispatch protocol forces SSH framing. Live with it.

## Why archive's config was likely "broken"

Ranked by frequency of bites in the wild:

1. **`nix.sshServe.trusted = true` not set** on the builder. Without
   it, the `nix-ssh` user isn't in `nix.settings.trusted-users`, so
   builds dispatch but fail with privilege errors ("user is not
   allowed to override system configuration"). Documented at
   [nixos/nix#2789](https://github.com/NixOS/nix/issues/2789).
2. **`publicHostKey` not provided** + `/root/.ssh/known_hosts` empty
   → root daemon (no TTY) cannot answer the trust prompt → "Broken
   pipe" with no useful error.
3. **`sshKey` path issues** — pointing at `/root/.ssh/id_ed25519`
   that doesn't exist (NixOS doesn't auto-generate root user keys).
   Host-key-as-user-key fixes this.
4. **`supportedFeatures` missing `big-parallel`** — quiet failure
   mode. Drvs marked `requiredSystemFeatures = [ "big-parallel" ]`
   (LLVM, kernels, chromium) silently stay local. "Kind of works"
   but never offloads anything heavy.
5. **Builder unreachable at build time** — `buildMachines` is static
   eval-time config; ygg-link-down doesn't break eval but produces
   long hangs that look like "broken."

The archive's commented-out block had `distributedBuilds = isDispatcher`
+ `buildMachines = optionals isDispatcher builderConfigs` but no
matching `nix.sshServe.trusted = true` on the builder side, no
`publicHostKey` populated, and the `mkBuilder` config had
`supportedFeatures = optional (!node.typeIs.edge) "big-parallel"`
(only). Looks like it would have hit (1), (2), and (4)
simultaneously.

## Recommended config

### Dispatcher (ouranos)

All values come from `horizon` — nothing hardcoded. `Node.builder_configs`
is already a `Vec<BuilderConfig>` populated by horizon-rs from the
cluster's `is_builder` ex-nodes. Each `BuilderConfig` carries
`{ host_name, ssh_user, ssh_key, supported_features, system,
systems, max_jobs }`. **Missing today**: `public_host_key` — needs
to be added to `BuilderConfig` (sourced from each builder's
`SshPubKeyLine`, which horizon already projects).

```nix
{ horizon, lib, ... }:
lib.mkIf horizon.node.isDispatcher {
  nix.distributedBuilds = true;
  nix.settings.builders-use-substitutes = true;

  nix.buildMachines = map (b: {
    inherit (b)
      hostName sshUser sshKey supportedFeatures system systems maxJobs;
    protocol      = "ssh-ng";
    speedFactor   = 10;
    publicHostKey = b.publicHostKey;   # ← needs horizon-rs schema add
  }) horizon.node.builderConfigs;

  programs.ssh.knownHosts = lib.listToAttrs (map (b: {
    name = b.hostName;
    value.publicKey = b.publicHostKeyLine;   # decoded form
  }) horizon.node.builderConfigs);
}
```

Field semantics ([nix-remote-build.nix
25.11](https://github.com/NixOS/nixpkgs/blob/release-25.11/nixos/modules/config/nix-remote-build.nix)):

- `sshKey` — path to a passphrase-less private key on local fs.
  Must NOT be in nix store. `/etc/ssh/ssh_host_ed25519_key` is mode
  600 root-owned by default — perfect.
- `publicHostKey` — base64-encoded `ssh_host_ed25519_key.pub` of
  the *builder*. Pre-populates known_hosts equivalent. MITM-proof
  even on ygg.
- `protocol = "ssh-ng"` — runs `nix-daemon --stdio` on remote.
  Newer/efficient. Plain `"ssh"` runs `nix-store --serve` (older).
- `builders-use-substitutes = true` — builder fetches its own deps
  from cache.nixos.org rather than streaming through laptop. Almost
  always correct.

To force-offload everything: `nix.settings.max-jobs = 0` locally.
Laptop becomes pure orchestrator.

### Builder (prometheus)

`horizon.node.dispatchersSshPubKeys` is already a list of
`SshPubKeyLine` for every ex-node that is `isDispatcher`.

```nix
{ horizon, lib, ... }:
lib.mkIf horizon.node.isBuilder {
  nix.sshServe = {
    enable    = true;
    protocol  = "ssh-ng";
    write     = true;
    trusted   = true;
    keys      = horizon.node.dispatchersSshPubKeys;
  };

  nix.settings.systemFeatures = [
    "nixos-test" "benchmark" "big-parallel" "kvm"
  ];
  services.openssh.enable = true;
}
```

What `nix.sshServe.enable = true` actually does ([nix-ssh-serve.nix
25.11](https://github.com/NixOS/nixpkgs/blob/release-25.11/nixos/modules/services/misc/nix-ssh-serve.nix)):

- Creates system user `nix-ssh` (group `nix-ssh`).
- Adds `Match User nix-ssh` block to sshd_config with `ForceCommand`
  set to `nix-daemon --stdio` (ssh-ng) or `nix-store --serve --write`
  (ssh). No PTY, no forwarding, no shell.
- `keys` is the **client authentication** allowlist — these are
  user-style pubkeys that go into `nix-ssh`'s authorized_keys. The
  fact that you paste *ouranos's host pubkey* there is the trick:
  it's a USER key from the auth event's perspective, sourced from
  the dispatcher's host key file.
- `trusted = true` is what unlocks the daemon to actually *build*
  on behalf of `nix-ssh` (not just substitute).

## Pitfall checklist

- [ ] `nix.sshServe.trusted = true` set
- [ ] `publicHostKey` populated (or known_hosts equivalent)
- [ ] `sshKey` is `/etc/ssh/ssh_host_ed25519_key`, not `/root/.ssh/id_*`
- [ ] `supportedFeatures` includes `big-parallel` (and `kvm` if
      building VM tests)
- [ ] `nix.sshServe.keys` is the *dispatcher's* host pubkey, not
      the builder's
- [ ] `nix.settings.builders` (string) NOT also set — `buildMachines`
      module renders into `/etc/nix/machines` for you
- [ ] `system` (string) NOT set if `systems` (list) is — `system`
      takes precedence

## Implementation in new criomos

Most plumbing already exists in horizon-rs:

| Need | Field | Status |
|---|---|---|
| dispatcher gate | `Node.is_dispatcher` | ✅ exists |
| builder gate | `Node.is_builder` | ✅ exists |
| builder list (nix.buildMachines source) | `Node.builder_configs: Vec<BuilderConfig>` | ✅ exists |
| dispatcher pubkeys (nix.sshServe.keys) | `Node.dispatchers_ssh_pub_keys` | ✅ exists |
| viewpoint node's own SSH pubkey | `Node.ssh_pub_key_line` | ✅ exists |
| **builder's SSH host pubkey** for `publicHostKey` | needs `BuilderConfig.public_host_key` | ❌ ADD |
| triggers from cluster proposal | per-node `is_builder` derivation rule | confirm — likely needs explicit gate |

One horizon-rs schema addition: `BuilderConfig.public_host_key:
SshPubKeyLine` (and `public_host_key_b64` if we want the base64
form pre-computed for `nix.buildMachines.<n>.publicHostKey`'s
expected format). Sourced from the ex-node's existing
`pub_keys.ssh` field — pure derivation, no new input.

Where the new criomos modules go:

- `modules/nixos/nix.nix` — extend with the two `mkIf` branches
  shown above (dispatcher / builder)
- horizon-rs — add `BuilderConfig.public_host_key`, bump
- CriomOS-pkgs / lojix-cli — irrelevant to this change

Mirrors archive's `exNodesSshPreCriomes` pattern but with the
trusted+publicHostKey fixes archive lacked.

## Sources

- [nix.dev — Setting up distributed builds](https://nix.dev/tutorials/nixos/distributed-builds-setup.html)
- [Official NixOS Wiki — Distributed build](https://wiki.nixos.org/wiki/Distributed_build)
- [nixpkgs 25.11 nix-remote-build.nix](https://github.com/NixOS/nixpkgs/blob/release-25.11/nixos/modules/config/nix-remote-build.nix)
- [nixpkgs 25.11 nix-ssh-serve.nix](https://github.com/NixOS/nixpkgs/blob/release-25.11/nixos/modules/services/misc/nix-ssh-serve.nix)
- [Nix 2.34 manual — Remote Builds](https://nix.dev/manual/nix/2.34/advanced-topics/distributed-builds)
- [Discourse — Serve nix store over SSH](https://discourse.nixos.org/t/serve-nix-store-over-ssh-and-use-as-substituter/24528)
  — host-key-as-user-key clarification
- [NixOS/nix#2789 — distributed builds require trusted remote user](https://github.com/NixOS/nix/issues/2789)
- [notashelf — Nix Remote Builders](https://notashelf.dev/posts/nix-remote-builders)
