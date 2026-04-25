# 2026-04-24 — `world` and `hob` removal: canonical replacement plan

Per directive: drop the legacy `world` (flake-context aggregator) and
`hob` (raw flake-input namespace) entirely. Use only canonical Nix.

## TL;DR

The actual scope is **smaller than feared**: 6 reference sites total
across the 33 modules, plus a few unused `inherit` lines to delete.
All replacements are mechanical given two design decisions
(answered below). `inputs` is now plumbed through CriomOS's
`specialArgs` so modules destructure it directly.

## What `world` and `hob` did (already documented)

- **`hob`** = raw flake inputs namespace from the legacy mkWorld
  pipeline. Used in CriomOS only for `hob.nixpkgs.{ref, rev}`.
- **`world`** = recursive aggregator merging inputs through
  `makeSpoke`. Used in CriomOS for `world.skrips.root` and
  `world.pkdjz.flake-registry`.

In the new architecture, both are replaced by direct `inputs.X`
access. No aggregator layer.

## The 6 reference sites

| File | Line | Old expression | Replacement |
|---|---|---|---|
| [nix.nix:39](../modules/nixos/nix.nix#L39) | `hob.nixpkgs ? ref` | `inputs.nixpkgs ? ref` (likely false now; conditional collapses) |
| [nix.nix:50](../modules/nixos/nix.nix#L50) | `inherit (hob.nixpkgs) rev` | `inherit (inputs.nixpkgs.sourceInfo) rev` |
| [nix.nix:81](../modules/nixos/nix.nix#L81) | `world.pkdjz.flake-registry` | inline JSON derived from `inputs.X.sourceInfo` for each declared input (see §below) |
| [normalize.nix:103](../modules/nixos/normalize.nix#L103) | `world.skrips.root` | **DELETE** (per user directive 2026-04-24 — not used anymore) |
| [userHomes.nix:15](../modules/nixos/userHomes.nix#L15) | `inputs.niri-flake.homeModules.config` | **OPEN QUESTION** — see below |
| [metal/default.nix:34](../modules/nixos/metal/default.nix#L34) | `inputs.brightness-ctl.packages.${pkgs.system}.default` | **already canonical** — input exists in flake.nix, just works once `inputs` is in specialArgs |

Plus unused `inherit` lines (declared, never used) — delete:
- [nix.nix:22](../modules/nixos/nix.nix#L22): `inherit (pkdjz) exportJSON;`
- [userHomes.nix:12](../modules/nixos/userHomes.nix#L12): `inherit (world) pkdjz;`

## Decisions taken

Per user (2026-04-24):

1. **`world.skrips.root`** — *delete*. Don't use anymore.
2. **`pkdjz.exportJSON name attrs`** — replace with
   `pkgs.writeText name (builtins.toJSON attrs)` everywhere. Minimize
   homegrown nix code.
3. **`hob.nixpkgs.{ref, rev}`** — read from `inputs.nixpkgs.sourceInfo`.
4. **`world.pkdjz.flake-registry`** — replace with inline JSON
   derived from `inputs.<each>.sourceInfo` (see canonical pattern
   below). No new flake-registry input needed.
5. **maikro user** — *delete* (test user, never used in production).

## Canonical pattern: `inputs` via specialArgs

**Done in this session:** [flake.nix](../flake.nix#L46) now passes
`inputs` to `nixosSystem`'s `specialArgs`:

```nix
specialArgs = { inherit horizon system inputs; };
```

Modules consume it directly:

```nix
{ horizon, inputs, pkgs, lib, ... }:
let
  brightnessCtl = inputs.brightness-ctl.packages.${pkgs.stdenv.hostPlatform.system}.default;
  homeModule = inputs.criomos-home.homeModules.default;
in
…
```

This is the standard NixOS module pattern — no `world` indirection,
no `hob`, no `pkdjz`. Verified non-breaking against `lojix eval`
for ouranos: still produces a real toplevel.drvPath.

## Canonical pattern: flake-registry from locked inputs

Replacement for `world.pkdjz.flake-registry`. Build the registry
JSON inline by walking `inputs.<each>.sourceInfo`:

```nix
{ inputs, pkgs, lib, ... }:
let
  inherit (lib) mapAttrsToList filterAttrs;

  # Subset of inputs that are useful as flake-registry pins on
  # deployed nodes (the things users typically `nix run` or
  # `nix develop` against).
  registered = {
    inherit (inputs)
      nixpkgs
      home-manager
      brightness-ctl
      criomos-home;
    # add as needed
  };

  mkEntry = name: input:
    let si = input.sourceInfo or { };
    in {
      from = { id = name; type = "indirect"; };
      to = filterAttrs (_: v: v != null && v != "") {
        type  = si.type or "github";
        owner = si.owner or null;
        repo  = si.repo or null;
        rev   = si.rev or null;
      };
    };

  registryJson = pkgs.writeText "criomos-flake-registry.json"
    (builtins.toJSON {
      version = 2;
      flakes = mapAttrsToList mkEntry registered;
    });
in
{
  nix.extraOptions = ''
    flake-registry = ${registryJson}
  '';
}
```

This pins each declared CriomOS input to its locked rev so
`nix flake show <id>` and child invocations on a deployed node use
the same revisions CriomOS was built against.

Edge case (per-node override): if needed later, add a horizon field
like `node.nix.customRegistry` and switch `nix.extraOptions`
conditionally — but not for v1.

## Implemented this session

1. Added `inputs` to specialArgs in [flake.nix](../flake.nix#L46).
2. Removed maikro user from [goldragon datom.nota](../repos/goldragon/datom.nota)
   (3 edits: UserProposal block, ClusterTrust.users entry, conversion-notes
   comment).
3. Fixed [checks/librist.nix](../checks/librist.nix):
   - Line 33: `"rist:$receiverIpAndPort"` → `"rist:${receiverIpAndPort}"`
   - Line 45: empty `writeScriptBin ""` → `writeScriptBin "simpleRistSenderTest"`
4. Verified all 6 goldragon nodes still project cleanly through
   horizon-cli and `lojix eval` for ouranos still produces a real
   drvPath.

## Bead updates

- [`CriomOS-8ae`](../.beads/) (P0, librist syntax) — **closing this report**.
- [`CriomOS-a4s`](../.beads/) (P1, nix.nix Phase 5) — **unblock**:
  design questions Q1–Q4 are answered. Concrete plan above.
- [`CriomOS-16v`](../.beads/) (P0, normalize.nix Phase 4) — note that
  `world.skrips.root` is a delete, not a replacement.

## Open question

**niri-flake from userHomes.nix**: [userHomes.nix:15](../modules/nixos/userHomes.nix#L15)
references `inputs.niri-flake.homeModules.config`. niri-flake is
currently a CriomOS-home input, not a CriomOS direct input. Three
options:

- (a) Add `niri-flake` as a direct CriomOS input. Defeats the
  CriomOS-home boundary somewhat (CriomOS-home was supposed to own
  all home-related inputs).
- (b) Re-export niri-flake from CriomOS-home so userHomes.nix can do
  `inputs.criomos-home.inputs.niri-flake.homeModules.config`. Works
  but couples CriomOS to CriomOS-home's input topology.
- (c) Move the import into CriomOS-home itself. Cleanest — CriomOS
  doesn't import niri at all; it lives entirely in CriomOS-home.
  Requires the CriomOS-home work to land first (its homeModules.default
  is currently empty stub).

Suggest **(c)**: defer until CriomOS-home is being wired up. For now,
when Phase 3 rewrites userHomes.nix, leave the import as-is (it
won't be evaluated until home-manager actually runs, which it won't
in v1 since CriomOS-home homeModules.default is empty).

## Net effect

After Phase 3 (userHomes), Phase 4 (normalize), and Phase 5 (nix.nix)
land, **`world`, `hob`, and `pkdjz` are gone from the codebase**.
The only "indirection" is the standard `inputs` arg on every module,
which is the canonical Nix pattern.
