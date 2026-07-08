# CriomOS OS update workflow

This workflow updates the operator home environment and the host OS lockfiles without activating a host. A later activation or boot-profile change is a separate authorized operation.

## Coordination and source shape

1. Register the assigned session/lane with `meta-orchestrate` before any write.
2. Use isolated date-named Jujutsu workspaces or clones from `main`; do not edit an existing shared checkout.
3. Claim the exact worktree paths and edited files under the lane. Do not claim `.beads/`.
4. Read `AGENTS.md`, `docs/ROADMAP.md`, and `bd list --status open` where the beads database is usable.
5. Use Jujutsu commands for all version-control operations.

The standard branch names for the 2026-07-08 update are:

- CriomOS-home: `criomos-home-update-2026-07-08`
- CriomOS: `criomos-update-2026-07-08`

## Home lock update

In the CriomOS-home update workspace:

```sh
nix flake update
jj status --no-pager
jj diff --stat
jj commit -m 'home: update flake inputs for YYYY-MM-DD'
jj bookmark set criomos-home-update-YYYY-MM-DD -r @-
jj git push --bookmark criomos-home-update-YYYY-MM-DD
```

`nix flake update` updates lockable inputs. Fixed URL inputs such as explicit VSIX, NPM tarball, or versioned file inputs do not advance unless their URL in `flake.nix` changes; those are non-flake fixed pins and are not opportunistically rewritten during an all-flake-input update.

## OS lock update

In the CriomOS update workspace, make the update-branch relationship explicit before updating the OS lock. The `criomos-home` input must consume the pushed Home update branch, for example:

```nix
criomos-home.url = "github:LiGoldragon/CriomOS-home/criomos-home-update-YYYY-MM-DD";
```

Then update and publish the OS branch:

```sh
nix flake update
jj status --no-pager
jj diff --stat
jj commit -m 'CriomOS: update flake inputs for YYYY-MM-DD'
jj bookmark set criomos-update-YYYY-MM-DD -r @-
jj git push --bookmark criomos-update-YYYY-MM-DD
```

This makes the rebuild self-contained: a build from the pushed CriomOS update revision includes the pushed CriomOS-home update branch through the committed `flake.nix` and `flake.lock`.

## Remote-only full OS rebuild

A full OS build must run from the pushed CriomOS revision and must not schedule local build jobs. Use the lojix-materialized target inputs and force remote builders:

```sh
result=$(
  nix build 'github:LiGoldragon/CriomOS/<pushed-criomos-update-rev>#nixosConfigurations.target.config.system.build.toplevel' \
    --no-link \
    --print-build-logs \
    --print-out-paths \
    --refresh \
    --option max-jobs 0 \
    --builders '@/etc/nix/machines' \
    --override-input system /var/lib/lojix/generated-inputs/goldragon/ouranos/full-os/system \
    --override-input horizon /var/lib/lojix/generated-inputs/goldragon/ouranos/full-os/horizon \
    --override-input deployment /var/lib/lojix/generated-inputs/goldragon/ouranos/full-os/deployment \
    --override-input secrets /var/lib/lojix/generated-inputs/goldragon/ouranos/full-os/secrets
)
```

`--option max-jobs 0` is the remote-only proof: the local machine has zero local build slots, so uncached builds must run through the configured builders. `--builders '@/etc/nix/machines'` selects the daemon-visible remote builder set. Keep the resulting store path in a shell variable and avoid recording raw store paths in durable prose.

A Lojix `Host ... Realize` request is acceptable only when the deployed Lojix source or logs prove the same remote-only shape (`--option max-jobs 0` and `--builders @/etc/nix/machines`). Realize is not activation. Do not use `SetBootProfile`, `TestActivation`, `ActivateNow`, or `ScheduleBootOnce` unless a separate task authorizes that host transition.

## Evidence to preserve

Closeout evidence includes:

- both branch names and worktree paths,
- changed files,
- flake-update summary, including fixed URL pins left unchanged,
- pushed commit identifiers,
- the exact remote-only build or admission command,
- rebuild result or failure point,
- coordination release and unregister status.
