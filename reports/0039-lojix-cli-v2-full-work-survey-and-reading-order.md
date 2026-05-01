# lojix-cli-v2 full work survey and reading order

## Purpose

This report is the current full survey of what remains to build in
`lojix-cli-v2`.

The next agent should treat this report as the implementation map for
v2. It names the required reading, the current code shape, the work
packages, the recommended order, and the verification expectations.

## MUST read before implementing

Read these in order before changing code.

### 1. Workspace contract

- `~/git/lore/INTENTION.md`
- `~/git/criome/ARCHITECTURE.md`
- `~/git/lore/AGENTS.md`
- `~/git/lojix-cli-v2/AGENTS.md`
- `~/git/lojix-cli-v2/ARCHITECTURE.md`

Why:

- `INTENTION.md` is upstream of every speed-vs-shape choice.
- `criome/ARCHITECTURE.md` keeps the forge-family and thin-client
  future in the right place without pulling v2 into a premature
  daemon rewrite.
- `lore/AGENTS.md` carries the workspace process rules: jj-only,
  always-push, report hygiene, and publish-step implication handling.
- `lojix-cli-v2/{AGENTS,ARCHITECTURE}.md` define the local carve-out:
  v2 is the safe rewrite fork and the live `lojix-cli` repo stays
  untouched.

### 2. v2 design source

- `~/git/CriomOS/reports/0038-lojix-local-config-and-home-deploy-design.md`

Why:

- This is the design authority for the Nota-native CLI direction,
  request-file/config shape, build-target generalization, and local
  home deploy semantics.

### 3. Operational lore

- `~/git/lore/lojix-cli/basic-usage.md`
- `~/git/lore/jj/basic-usage.md`
- `~/git/lore/bd/basic-usage.md`

Why:

- `lojix-cli/basic-usage.md` captures the current operational contract
  of the live tool: action meanings, pinning expectations, root-SSH
  model, and deploy risks that v2 must preserve or intentionally
  replace.
- `jj/basic-usage.md` is load-bearing because this repo is jj-only and
  the workspace requires immediate commit+push.
- `bd/basic-usage.md` is required because the remaining work is tracked
  in the repo's bead database, not in files or chat.

### 4. Implementation style lore

- `~/git/lore/rust/style.md`
- `~/git/lore/rust/nix-packaging.md`

Why:

- `rust/style.md` is directly relevant to the next changes: v2 needs
  new typed request objects, target types, and activation nouns rather
  than bolting more flags onto `main.rs`.
- `rust/nix-packaging.md` matters because v2's flake and checks must
  stay healthy while the binary/package identity and test layout
  evolve.

## Current repo shape

### Repo status

`lojix-cli-v2` is a fresh fork of the working `lojix-cli` monolith.
Its package and binary identity are distinct (`lojix-cli-v2`), but the
runtime code is still the copied baseline.

Open beads:

- `lojix-cli-v2-hy7` — Nota-first request decoding
- `lojix-cli-v2-8p5` — Generalize build target selection
- `lojix-cli-v2-m7y` — Add local home activation flow
- `lojix-cli-v2-s8t` — Validate home users before Nix
- `lojix-cli-v2-cf1` — Add request-file default loading

### Code map

- [src/main.rs](/home/li/git/lojix-cli-v2/src/main.rs)
  Clap-first entrypoint. Builds one `DeployRequest` from `RunArgs`.
- [src/deploy.rs](/home/li/git/lojix-cli-v2/src/deploy.rs)
  Pipeline coordinator. Reads proposal, projects horizon, materializes
  override flakes, builds, copies, and activates.
- [src/build.rs](/home/li/git/lojix-cli-v2/src/build.rs)
  Hardcodes the system toplevel attr path and maps `BuildAction` to
  `nix eval` or `nix build`.
- [src/activate.rs](/home/li/git/lojix-cli-v2/src/activate.rs)
  System-only activation behavior: root SSH, system profile writes,
  EFI reconciliation, boot-once logic.
- [tests/argv.rs](/home/li/git/lojix-cli-v2/tests/argv.rs)
  Wire-shape assertions for nix build/copy/ssh activation argv.
- [tests/eval.rs](/home/li/git/lojix-cli-v2/tests/eval.rs)
  End-to-end eval smoke test against local `goldragon` and local
  `CriomOS`.

### Current constraints visible in code

1. `src/main.rs` assumes Clap subcommands are canonical. There is no
   typed top-level Nota request.
2. `DeployRequest` in [src/deploy.rs](/home/li/git/lojix-cli-v2/src/deploy.rs)
   has no target concept; it assumes "system deploy" everywhere.
3. `NixBuild::nix_argv()` in [src/build.rs](/home/li/git/lojix-cli-v2/src/build.rs)
   hardcodes:
   `#nixosConfigurations.target.config.system.build.toplevel`
4. `SystemActivation` in [src/activate.rs](/home/li/git/lojix-cli-v2/src/activate.rs)
   owns all post-build effect behavior, and all of it is root/system
   specific.
5. The current tests anchor only the system path. There are no tests
   for request decoding, target selection, or home activation.

## Known inherited failure

`cargo test` currently passes the unit/argv/builder-validation tests
but the end-to-end `tests/eval.rs` smoke test fails in the copied
baseline because the local `CriomOS` path it evaluates tries to open:

`packages/criomos-deploy/default.nix`

and that file is absent in the current source tree used by the test.

This is important for the next agent because:

- it is not a v2-specific regression;
- it means the test suite is not fully green before feature work even
  starts;
- the agent should decide explicitly whether to update the test fixture,
  gate the test, or repair the local CriomOS eval path.

Do not silently treat this as a v2 breakage.

## Work to do

### A. Replace Clap-first entry with a typed Nota-first request model

Design source:

- `0038` section `## Nota-Native Invocation`

Current gap:

- `main.rs` only knows `deploy|build|eval` subcommands and `RunArgs`.

Required outcome:

- one top-level typed request enum decoded from Nota;
- dispatch rule:
  - first argv starts with `(` → join argv and decode inline Nota
  - otherwise first argv is a path → read and decode file contents
  - no argv → read default request path
- compatibility subcommands may remain temporarily, but they must map
  into the same typed request model.

Likely code work:

- new request/config module
- `main.rs` stops building `DeployRequest` directly
- decoder-based tests for inline vs file-path input

Why this matters first:

- until the top-level request is typed, every later design change gets
  forced back through Clap enums and optional flags.

### B. Separate target identity from action identity

Design source:

- `0038` sections `### Typed Request`, `### Split Request Target From Action`

Current gap:

- `BuildAction` currently spans both "how should we drive the build"
  and "what domain are we building".

Required outcome:

- a target type that distinguishes at least:
  - system
  - home `{ user }`
- action/mode types that distinguish:
  - system actions: `Eval | Build | Boot | Switch | Test | BootOnce`
  - home modes: `Build | Profile | Activate`

Why this split is load-bearing:

- system and home have genuinely different activation semantics;
- a `--home-only` boolean would hide a domain split that the type
  system should expose.

### C. Generalize build attr selection

Design source:

- `0038` section `## Home Deploy Semantics`

Current gap:

- `NixBuild::nix_argv()` hardcodes the system attr path.

Required outcome:

- target-derived attr generation:
  - system:
    `nixosConfigurations.target.config.system.build.toplevel`
  - home:
    `nixosConfigurations.target.config.home-manager.users.<user>.home.activationPackage`

Likely refactor:

- `NixBuild` should stop carrying only `action`; it needs a typed build
  target or a typed requested realization domain.

Tests required:

- existing system attr test stays
- new exact home attr test lands

### D. Add local home activation as a separate activation path

Design source:

- `0038` sections `### Activation Modes`, `### Local Home Activation`,
  `### Add HomeActivation`

Current gap:

- `SystemActivation` is the only post-build effect path.

Required outcome:

- separate `HomeActivation` sibling to `SystemActivation`
- local home modes:
  - `Build` → no activation side effect
  - `Profile` → set `~/.local/state/nix/profiles/home-manager`
  - `Activate` → set profile then run `<gen>/activate`

Explicit non-goal for first cut:

- remote home deployment

Why separate nouns matter:

- root/system bootloader logic and user home-session logic are
  different concerns; forcing them through one activation noun will
  produce ugly branching.

### E. Validate home users at the horizon boundary

Design source:

- `0038` section `### Validate User`

Current gap:

- builder validation exists, but no user validation does because there
  is no home target yet.

Required outcome:

- after projection, before Nix, fail clearly if the requested user is
  absent from projected `horizon.users`.

This belongs next to:

- builder resolution in [src/deploy.rs](/home/li/git/lojix-cli-v2/src/deploy.rs)

It should fail with a direct request-level error rather than a later
Nix evaluation failure.

### F. Decide the actual first config/request-file shape

Design source:

- `0038` sections `## Local Config File` and `### Optional Alias Layer`

Current gap:

- there is no request-file loading yet;
- there is no config/default resolution yet.

Required outcome for first implementation:

- support persisted Nota requests from:
  1. explicit first non-inline argv path
  2. `LOJIX_CONFIG`
  3. `$XDG_CONFIG_HOME/lojix/config.nota`
  4. `~/.config/lojix/config.nota`

Important design judgment:

- do not jump straight to a richer `LojixConfig` alias/default grammar
  unless the simple persisted-request shape proves insufficient.
- if a richer alias layer is added, the Rust type order is the Nota
  wire contract and must be documented via golden encoder tests, not
  invented prose examples.

### G. Preserve pinning discipline

Design source:

- `0038` section `### Pinning`
- `lore/lojix-cli/basic-usage.md` section `## Always pin --criomos ...`

Current gap:

- the copied baseline still allows an unpinned default
  `github:LiGoldragon/CriomOS`.

Required outcome:

- request-file/default-loading work must not normalize unpinned
  effect-bearing deploys into the new default UX.

Recommended first step:

- reject or loudly warn on unpinned effect-bearing requests unless an
  explicit escape hatch is present.

Second-phase possibility:

- a jj-based resolver that composes a pushed GitHub revision from local
  workspace state.

### H. Repair or replace the end-to-end smoke test strategy

Current gap:

- `tests/eval.rs` is bound tightly to local machine state:
  `goldragon/datom.nota`, `path:/home/li/git/CriomOS`, and a CriomOS
  source path that currently fails.

Required outcome:

- the repo needs a deliberate test strategy for v2 changes:
  - pure request/decoder tests
  - attr-shape tests
  - activation argv tests
  - horizon-boundary validation tests
  - optional machine-local smoke tests gated clearly

The next agent should avoid growing feature work on top of an
ambiguous "sometimes broken" integration test story.

## Recommended implementation order

1. Stabilize the test story enough that new work can be verified
   intentionally.
2. Land the typed request model and Nota-first dispatch.
3. Land target/action split and build attr generalization.
4. Land local home activation.
5. Land pre-Nix user validation.
6. Land request-file/default-path loading.
7. Land pinning guardrails on the new request surface.
8. Only after local home flows work, design remote home deployment.

This order keeps the first deep refactor on the shape boundary
(`main.rs` and request typing), then moves inward through build and
activation.

## Verification expectations

The next agent should not stop at code movement. Each major work step
should leave behind exact tests.

Minimum expected test additions:

- inline Nota decode path
- file-path decode path
- default-path fallback behavior
- compatibility-subcommand to typed-request mapping
- exact system attr
- exact home attr
- home user missing failure before Nix
- local home profile command shape
- local home activate command shape
- rejection of system-only actions on home targets

The existing exact-argv style in [tests/argv.rs](/home/li/git/lojix-cli-v2/tests/argv.rs)
is the right precedent.

## What not to do

- Do not edit the live `~/git/lojix-cli` repo as part of v2 work.
- Do not add a new public `homeConfigurations` surface to CriomOS.
- Do not collapse immediately into the long-term forge thin-client
  destination. That future is real, but it is not the first v2 move.
- Do not invent a second user-facing config grammar before trying the
  simpler "saved Nota request" shape.
- Do not blur system and home semantics behind booleans when the
  domains differ structurally.

## Immediate next bead to claim

If one agent starts implementation from this report, the best first
claim is:

- `lojix-cli-v2-hy7` — Nota-first request decoding

Reason:

- it creates the top-level typed shape that every later feature needs,
  and it prevents the rest of the redesign from accreting as more
  optional Clap flags.
