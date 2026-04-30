# lojix Local Config and Home Deploy Design

## Request

Li wants `lojix-cli` to stop requiring the same deploy parameters on
every invocation, and to deploy home profiles directly:

- no repeated `--cluster`, `--node`, `--source`, `--criomos`;
- support a local config file;
- support Home Manager profile build/deploy flows, not only NixOS
  system generations.

This report is research and design only. No `lojix-cli` code was
changed.

## Current State

`lojix-cli` has three top-level subcommands:

- `eval`
- `build`
- `deploy`

They all parse the same `RunArgs`:

- `--cluster`
- `--node`
- `--source`
- `--criomos`
- `--action`
- `--builder`

`build_request` converts those strings into:

- `ClusterName`
- `NodeName`
- optional builder `NodeName`
- `ProposalSource`
- `FlakeRef`
- `BuildAction`

The actor pipeline then does this:

1. `ProposalReader` reads the cluster proposal nota.
2. `HorizonProjector` projects `(cluster, node)` through
   `horizon-lib`.
3. `HorizonArtifact` writes local override flakes:
   `~/.cache/lojix/horizon/<cluster>/<node>/` and
   `~/.cache/lojix/system/<system>/`.
4. `NixBuilder` evaluates or builds this fixed attribute:
   `nixosConfigurations.target.config.system.build.toplevel`.
5. If the action activates, `ClosureCopier` copies the system closure
   to the target over `ssh-ng://root@...`.
6. `Activator` runs the system activation path over SSH as root:
   `nix-env -p /nix/var/nix/profiles/system --set ...` and
   `switch-to-configuration`.

The hardcoded system attr path is the key limitation. The projection
and artifact phases are already reusable for home deploys; the build
target and activation target are not.

## Local Config File

### Format

Use Nota, not TOML, for the first implementation.

Reasons:

- `lojix-cli` already depends on `nota-codec`.
- `goldragon/datom.nota` is already the ecosystem's operator-facing
  data format.
- A Nota config can be typed with `NotaRecord`/`NotaEnum`, consistent
  with `horizon-rs`.
- Avoids adding another configuration grammar and dependency for the
  transitional CLI.

### Location

Resolution order:

1. Explicit `--config <path>`.
2. `LOJIX_CONFIG`.
3. `$XDG_CONFIG_HOME/lojix/config.nota`.
4. `~/.config/lojix/config.nota`.

If no config file exists, the CLI can keep the current explicit-flag
behavior.

### Shape

The config should name targets, not "profiles", to avoid colliding
with Home Manager/Nix profiles.

Nota records in this ecosystem are positional. The file should decode
directly into one top-level record; the record name is the Rust type
used by the decoder, not syntax written into the file. Nested records
are positional too. Enum variants are the only named constructors.

Suggested first wire shape:

```nota
default
[
  (Entry default
    (goldragon
     ouranos
     "/home/li/git/goldragon/datom.nota"
     "github:LiGoldragon/CriomOS"
     None
     (Home li)))

  (Entry ouranos-system
    (goldragon
     ouranos
     "/home/li/git/goldragon/datom.nota"
     "github:LiGoldragon/CriomOS"
     None
     System))
]
```

The corresponding Rust concepts:

```rust
struct LojixConfig {
    default: TargetAlias,
    targets: BTreeMap<TargetAlias, TargetConfig>,
}

struct TargetConfig {
    cluster: ClusterName,
    node: NodeName,
    source: ProposalSource,
    criomos: FlakeRef,
    builder: Option<NodeName>,
    target: DeployTarget,
}

enum DeployTarget {
    System,
    Home { user: UserName },
}
```

`TargetAlias` can be a small local newtype. `UserName` already exists
in `horizon-lib`.

### CLI UX

Keep existing commands working, but make args optional when config can
fill them:

```sh
lojix-cli eval
lojix-cli build
lojix-cli deploy --action boot
lojix-cli deploy --target ouranos-system --action boot
lojix-cli home build
lojix-cli home deploy
lojix-cli home deploy --target default --user li
```

Recommended command split:

- `lojix-cli system eval|build|deploy`
- `lojix-cli home eval|build|deploy`
- keep legacy `eval|build|deploy` as aliases for `system ...` during
  the transition.

This is clearer than `deploy --home-only` because system and home have
different activation semantics. A boolean flag would hide that.

### Override Precedence

Use this merge order:

1. CLI flags.
2. Selected config target.
3. Config defaults.
4. Built-in defaults.

For example, a config target can provide `(cluster, node, source,
criomos, user)`, while the operator still overrides just the action:

```sh
lojix-cli deploy --action boot
lojix-cli home deploy --mode activate
```

### Pinning

The current docs require deploys to pin `--criomos` to a pushed
revision because unpinned `github:LiGoldragon/CriomOS` can reuse stale
flake eval cache.

A local config file should not regress this.

There are two reasonable phases:

1. **MVP:** config stores a literal flake ref. If it is unpinned and
   the command is effect-bearing, warn loudly or reject unless
   `--allow-unpinned` is passed.
2. **Better operator UX:** config stores a repo resolver, for example
   "local jj repo + GitHub base ref". `lojix-cli` resolves the current
   pushed `main` commit and composes
   `github:LiGoldragon/CriomOS/<rev>`.

The resolver phase should use `jj`, not `git`, because these repos are
jj-only operationally. It should also verify that the local bookmark
matches the remote bookmark before deploying, otherwise the flake fetch
will not see the intended code.

## Home Deploy Semantics

### Build Attribute

Home deployment should build:

```text
nixosConfigurations.target.config.home-manager.users.<user>.home.activationPackage
```

That preserves the existing architecture:

- CriomOS remains the public system surface.
- Horizon still enters only through the projected `horizon` flake
  input.
- Home still lives in `CriomOS-home` and is consumed through
  `inputs.criomos-home.homeModules.*`.

Do not add a standalone `homeConfigurations` surface to CriomOS just
to satisfy `lojix-cli`; that would create a second public deployment
surface.

### Validate User

After projection, validate that the requested `UserName` exists in
`horizon.users`.

Fail before running Nix if the user is absent:

```text
user li not present in projected horizon users for goldragon/ouranos
```

This mirrors existing builder validation: catch an invalid request at
the horizon boundary, not during a later Nix build.

### Activation Modes

Home Manager activation is not equivalent to system boot deployment.
It may relink compositor config, reload the user systemd manager,
restart `darkman`, refresh D-Bus service files, and trigger niri's
live config reload.

So home deploy needs explicit modes:

| mode | action | risk |
|---|---|---|
| `build` | build activation package only | no profile or session change |
| `profile` | build and set `~/.local/state/nix/profiles/home-manager` | profile changes, no activation |
| `activate` | build, set profile, run `activate` as the target user | live session mutation |

`home deploy` should probably default to `profile`, not `activate`,
unless Li explicitly prefers current `home-manager switch` behavior.
For interactive work, `activate` is useful, but the name must make the
risk obvious.

### Local Home Activation

For local target/user:

```sh
nix build --no-link --print-out-paths \
  '<criomos>#nixosConfigurations.target.config.home-manager.users.<user>.home.activationPackage' \
  --override-input horizon path:... \
  --override-input system path:...

nix-env -p "$HOME/.local/state/nix/profiles/home-manager" --set "$GEN"
"$GEN/activate"
```

`lojix-cli` should avoid printing the realised store path in normal
operator logs. Internally it still needs to hold the path as a typed
`StorePath`.

### Remote Home Activation

Remote home deployment is a second phase.

The current system deploy path assumes root SSH:

- `nix copy --to ssh-ng://root@<target>`
- activation over `ssh root@<target>`

Home activation should run as the target user, not root. For a remote
target that means the activation target is not `SshTarget` alone. It is
something like:

```rust
struct HomeTarget {
    node: SshTarget,
    user: UserName,
}
```

Remote home deploy needs decisions on:

- whether closure copy goes to root's daemon connection or the user's
  SSH connection;
- whether `nix-env -p ~/.local/state/nix/profiles/home-manager --set`
  runs under `ssh <user>@<target>`;
- how to ensure user SSH keys exist for non-root login;
- whether `systemd-run --user` should be used for activation so it
  survives SSH disconnects.

Do local home deploy first. It covers the actual current need and
avoids conflating two separate problems.

## Persistence Caveat

Today's incident exposed an important architecture fact:

CriomOS embeds Home Manager in the NixOS system generation. At boot,
NixOS runs `hm-activate-<user>` from the current system generation and
relinks home files from the `criomos-home` revision pinned by that
system generation.

Therefore, a standalone home-only activation is a live overlay. It is
not necessarily reboot-persistent.

Observed state after reboot:

- `~/.local/state/nix/profiles/home-manager` still pointed at the
  manually deployed generation.
- `/home/li/.config/niri/config.kdl` had been re-linked by boot-time
  `hm-activate-li` from the current NixOS system generation.

Implication:

- `lojix-cli home deploy --mode activate` is for immediate live home
  iteration.
- durable home changes still require a system generation that pins the
  desired `CriomOS-home` revision.
- `lojix-cli` should say this directly after home activation:
  "live home generation activated; reboot persistence requires a
  system deploy containing the same CriomOS-home revision."

Trying to make standalone home-only activation durable by fighting the
boot-time HM activation would create split-brain state. Do not do that
without a broader CriomOS architecture change.

## Code Structure

### New `config` module

Add `src/config.rs`:

- `LojixConfig`
- `TargetAlias`
- `TargetConfig`
- config path discovery
- Nota decode
- CLI/config merge into a fully typed request

`main.rs` should become mostly:

1. parse CLI;
2. load optional config;
3. resolve command into a typed request;
4. send request to coordinator.

### Split Request Target From Action

Today `DeployRequest` assumes the build target is the system toplevel.

Change it to include a target:

```rust
pub struct DeployRequest {
    pub cluster: ClusterName,
    pub node: NodeName,
    pub builder: Option<NodeName>,
    pub action: BuildAction,
    pub source: ProposalSource,
    pub criomos: FlakeRef,
    pub target: DeployTarget,
}

pub enum DeployTarget {
    System,
    Home { user: UserName, mode: HomeMode },
}
```

### Generalize `NixBuild`

Rename conceptually from "build system toplevel" to "realize target".

Current hardcoded attr:

```text
<flake>#nixosConfigurations.target.config.system.build.toplevel
```

Target-derived attrs:

```text
System:
<flake>#nixosConfigurations.target.config.system.build.toplevel

Home(li):
<flake>#nixosConfigurations.target.config.home-manager.users.li.home.activationPackage
```

`BuildAction::Boot/Switch/Test/BootOnce` only applies to `System`.
Home should use `HomeMode`:

```rust
enum HomeMode {
    Build,
    Profile,
    Activate,
}
```

Avoid overloading `BuildAction` for both domains. The system action
space and home action space are genuinely different.

### Add `HomeActivation`

Add a sibling to `SystemActivation`:

```rust
pub struct HomeActivation {
    pub user: UserName,
    pub store_path: StorePath,
    pub mode: HomeMode,
}
```

For local MVP:

- `Build`: no activation object is needed.
- `Profile`: run `nix-env -p ~/.local/state/nix/profiles/home-manager --set <gen>`.
- `Activate`: run profile set, then `<gen>/activate`.

Keep this separate from `SystemActivation`; system activation is root,
bootloader, and EFI state. Home activation is user profile and user
session state.

### Coordinator Finish Logic

Current `finish` is system-only:

```text
if action activates:
  copy closure to root target
  system activate as root
```

New shape:

```text
System:
  if action activates:
    copy closure
    run SystemActivation

Home local:
  if mode == Build:
    print/summarize success
  if mode == Profile:
    run HomeActivation(profile)
  if mode == Activate:
    run HomeActivation(activate)
```

Do not run `ClosureCopier` for local home MVP.

## Tests

Add tests at the existing wire-shape level:

- config discovery:
  - explicit `--config` wins;
  - missing config keeps legacy required-flag behavior;
  - config target fills missing CLI args;
  - CLI flags override config values.
- system attr remains unchanged.
- home attr is exactly:
  `nixosConfigurations.target.config.home-manager.users.li.home.activationPackage`.
- system actions reject home targets:
  `lojix-cli home deploy --action boot` should fail at parse/resolve.
- home modes reject system-only behavior:
  no `nix copy --to ssh-ng://root@...`;
  no `switch-to-configuration`;
  no `/nix/var/nix/profiles/system`.
- home user validation catches an absent user before Nix invocation.
- activation argv for local profile uses:
  `nix-env -p ~/.local/state/nix/profiles/home-manager --set`.

The existing tests already assert exact argv shapes; extend that style.

## Recommended Implementation Order

1. Add `DeployTarget`, `HomeMode`, and generalized build attr
   generation. Keep CLI flags explicit. Verify `lojix-cli home build`
   can build Li's activation package.
2. Add local `HomeActivation` for `profile` and `activate`.
3. Add config file loading and config/CLI merge.
4. Add unpinned-ref guard for effect-bearing deploys.
5. Add optional jj-based ref resolver for "use pushed main" UX.
6. Only after local home works, design remote home deploy.

This order keeps the first patch small: one new build target and one
local activation path, without changing projection or system deploy
semantics.

## Suggested Beads

The existing `CriomOS-4yt` covers home-only deploy broadly. Add one
separate bead:

```text
lojix-cli: load deploy defaults from local config file
```

Keep the bead short; this report carries the design detail.
