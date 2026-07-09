# CriomOS OS update workflow

This workflow updates the operator home environment and the host OS lockfiles without activating a host. A later activation or boot-profile change is a separate authorized operation. The update is a forward-fix loop: keep the update branches moving, repair ordinary evaluation and build fallout in source, repin dependents, and retry the remote-only rebuild until it completes or reaches a true policy or safety stop.

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

## Compatibility breakage loop

Small update breakages are part of the update, not a reason to abandon the branch. Continue forward when the failure is ordinary flake-update fallout: renamed Home Manager options, upstream module migrations, new upstream assertions, lock repins, package build fixes, or evaluation compatibility changes that are contained in CriomOS or its source inputs.

If a compatibility worker aborts after reaching a green check but before committing, preserve the producer checkout before any restore or repin: inspect the dirty state, rerun the cheapest confirmation check that is safe, commit and push the intended update branch, then repin consumers to that pushed revision.

1. Read the failing upstream module or source at the locked revision before editing; do not guess from memory.
2. Fix the compatibility issue in the owning source repository, preserving behavior where practical.
3. When exact parity is not safe or the upstream model changed shape, choose the closest safe equivalent and document the migration note in the source or workflow guidance. If a new upstream assertion covers an integration the profile does not actually use, disable that narrow integration instead of upgrading or redesigning unrelated packages. If Rust/Cargo vendoring fails because a lockfile carries duplicate git packages with the same name/version from different revisions, refresh the affected producer lockfile and any checked-in generated artifacts, push that producer branch, and explicitly repin the CriomOS input to it. If a dependency lock refresh exposes stale checked-in schema artifacts, fix the producer schema/artifacts under the current generator, push that producer branch, then repin each dependent branch explicitly; do not patch vendored or store copies.
4. Commit and push the producer branch.
5. Repin the consuming CriomOS lock to the new producer commit without resolving unrelated mutable heads.
6. Commit and push CriomOS, then rerun the full remote-only rebuild from the pushed CriomOS revision.

Stop only for an activation or switch request, destructive or irreversible action, secrets/private exposure, credential or account requirements, high-blast-radius redesign, or a true policy/design fork. Do not stop for ordinary evaluation/build fallout that can be fixed forward on the update branches.

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
