# 2026-04-24 — three-flake architecture implemented

Followup to [reports/2026-04-24-nix-rewrite-and-pkgs-input.md](2026-04-24-nix-rewrite-and-pkgs-input.md).
That report's §4 described an earlier (wrong) interpretation of the
proposal. The user clarified, I tested, and the corrected design is
now implemented across CriomOS and lojix.

## What landed

### CriomOS

- [stubs/no-system/flake.nix](../stubs/no-system/flake.nix) —
  default stub for the `system` input; throws on access with
  guidance toward lojix.
- [pkgs-flake/flake.nix](../pkgs-flake/flake.nix) — stable
  intermediary that calls `import nixpkgs { system; }`. Lives
  inside CriomOS but is consumed via `path:./pkgs-flake`, giving
  it a separate flake-eval cache key.
- [flake.nix](../flake.nix) — three new inputs:
  - `inputs.system.url = "path:./stubs/no-system"` — lojix overrides.
  - `inputs.pkgs.url = "path:./pkgs-flake"` with `inputs.nixpkgs`
    and `inputs.system` follows-propagated from CriomOS.
  - `inputs.horizon.url = "path:./stubs/no-horizon"` (unchanged).
- `lib.nixosSystem` now receives a pre-built `pkgs` and imports
  `nixpkgs.nixosModules.readOnlyPkgs` to enforce no overlay /
  config mutation. Drops the explicit `system` arg (would conflict
  with `readOnlyPkgs`); modules can read `system` from specialArgs.

### lojix

- New [SystemDir](../repos/lojix/src/artifact.rs) sibling to
  `HorizonDir`. Cache layout:
  - `~/.cache/lojix/horizon/<cluster>/<node>/` (per-node)
  - `~/.cache/lojix/system/<system-tuple>/` (per-arch — shared
    across nodes targeting the same arch)
- `HorizonArtifact::materialize` writes both, returns a
  `MaterializedArtifact { horizon_uri, system_uri, … }`.
- `NixInvocation` emits both `--override-input horizon` and
  `--override-input system`.
- Tests updated for the new dir layout; both pass.

## Verified

- `lojix eval --cluster goldragon --node tiger --source … --criomos path:/home/li/git/CriomOS`
  reaches the nix evaluation; fails as expected on missing
  `fileSystems`/`bootloader` (still [CriomOS-52j](../.beads/) — not
  this report's concern).
- `pkgsProbe` flake output evaluates to `"x86_64-linux"` —
  proves `pkgs` was instantiated through the pkgs-flake with the
  system the lojix-supplied input carries.
- Both materialization narHashes are deterministic across runs.

## Cache property — measured

Quick timing on an otherwise-cold eval cache, evaluating
`nixosConfigurations.target.config.system.build.toplevel.drvPath`:

| Variation | Time | Cache state |
|---|---|---|
| Cold start, system-x86 + tiger | 1.96s | full miss |
| Re-run, identical | 1.49s | full hit |
| Same system, different horizon (balboa) | 2.23s | pkgs-flake hit; horizon eval fresh |
| Different system (arm), same horizon | 2.08s | pkgs-flake miss; horizon hit |

Numbers are small because the evaluation halts at NixOS module
assertions (no real fileSystems wired). The real speedup will
materialize once [CriomOS-52j](../.beads/) lands and the eval
actually walks pkgs deeply.

The structural property — pkgs eval cache key isolated from
horizon — holds: changing horizon doesn't invalidate the
pkgs-flake's cache row, because `pkgs.outputs` depend only on
`(nixpkgs.narHash, system.narHash)`, both of which `follows`
propagates to from CriomOS.

## Decisions taken (record)

- **pkgs-flake lives inside CriomOS** as a subdirectory, not in a
  separate repo. Reasoning: it's tiny (4 lines of Nix), tightly
  coupled to CriomOS's `nixpkgs` choice, and `path:./pkgs-flake`
  inputs are content-addressed to the subdir contents only — so the
  cache property holds either way. Spinning up its own repo wasn't
  worth the overhead.
- **No new `SystemArtifact` actor** — `HorizonArtifact` does both.
  Cohesive: lojix produces one bundle of artifacts per deploy; the
  user-facing concept is "materialize what nix needs", not "two
  separate things".
- **`readOnlyPkgs` is mandatory.** Imported automatically by
  CriomOS's flake; modules cannot set `nixpkgs.config` /
  `nixpkgs.overlays`. Aligned with the existing
  `nixpkgs.overlays = mkOverride 0 [ ]` stance — but now enforced.

## What's still v2

- **Tarball / portable artifacts.** Today both overrides are local
  `path:` URIs. For cross-machine deploys the publish step (per
  [§4 of 2026-04-24-ractor-tool-design.md](2026-04-24-ractor-tool-design.md))
  still needs to land — `tarball+url?narHash=…` for both system and
  horizon, with the deterministic-naming convention. Tracked as
  [`lojix-d56`](../repos/lojix/.beads/) (P1).
- **The module rewrite ([CriomOS-52j](../.beads/)).** Still the
  largest remaining piece. Plan in
  [reports/2026-04-24-nix-rewrite-and-pkgs-input.md §3](2026-04-24-nix-rewrite-and-pkgs-input.md).
- **Real perf measurement.** Cache benefits are theoretical until
  modules access pkgs.X heavily. Re-measure after CriomOS-52j.

## Open questions

1. **Where does `nixpkgs-rev` get pinned for the pkgs-flake?**
   Currently CriomOS's `flake.lock` pins it (via the top-level
   `nixpkgs` input that propagates through `follows`). Bumping
   nixpkgs is a single `nix flake lock --update-input nixpkgs` in
   CriomOS — pkgs-flake follows automatically. Confirm this matches
   intent. If you want lojix-controlled nixpkgs revs (e.g. per
   cluster from goldragon's `datom.nota`), we'd add a `nixpkgs`
   override path. Suggest: keep CriomOS-pinned for now.

2. **Should pkgs-flake later split out to its own repo?**
   Probably not. Inside CriomOS, it's self-documenting and version-
   coupled. If a non-CriomOS consumer ever wants the same
   "instantiate nixpkgs by content-addressed system" pattern,
   they can copy the 4 lines.

3. **Does the cache benefit outweigh the readOnlyPkgs rigidity?**
   Today yes (no overlays anywhere); revisit if a future module
   genuinely needs to override a nixpkgs package. The escape hatch
   is to define an overlay-bundled package as a CriomOS package
   (in [packages/](../packages/)) instead, which is the canonical
   blueprint pattern anyway.
