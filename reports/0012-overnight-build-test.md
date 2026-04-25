# 2026-04-25 — overnight test of crane+fenix migration + nixpkgs bump

User went to sleep after asking: "update nixpkgs to latest nixos-unstable,
and test build everything". This report tracks the autonomous run.

## Setup

- **nixpkgs**: bumped from `b12141ef` (Apr 18) → `0726a0ec` (Apr 22, current
  nixos-unstable head) across CriomOS + lojix + horizon-rs + clavifaber +
  brightness-ctl. All flake inputs floating `?ref=nixos-unstable`.
- **All Rust crates**: now on crane + fenix per
  [tools-documentation/rust/nix-packaging.md](../../tools-documentation/rust/nix-packaging.md).
- **CriomOS-home**: niri-flake import gate hardened to
  `inputs ? niri-flake` (was just `inputs != null`).

## Tests run

### Phase 1 — Rust crates `nix build .#packages.x86_64-linux.default`

Ran sequentially after nixpkgs bump:

| repo | result | store path |
|------|--------|------------|
| lojix | ✓ | `lknbx8jims2155gy8gb2c1c6hipcp2jd-lojix-0.1.0` |
| horizon-rs | ✓ | `qbq34sa88iijs8c5yyyfcvnrypkam79x-horizon-cli-0.0.1` |
| clavifaber | ✓ | `idzbcav2q2ll027lnczl6nhf1phmxk0m-clavifaber-0.1.0` |
| brightness-ctl | ✓ | `gcz414mpx3vz0ivski2rapngkyc57m1x-brightness-ctl-0.1.0` |

### Phase 2 — `lojix eval` all 6 goldragon nodes

All passed against the new nixpkgs. Drv hashes:

```
balboa     43d80vwhlnzki0nm2mxcyiy87dr339q2
klio       j73fvnlfbyk1f0h4qdha6vln1zrsf09m
ouranos    vv0nf2wsmxcajcr1r5mffdwh4axasqdc
prometheus dkrpijbs5w4n3rj2qzzyjg9a4n9n3jac
tiger      d4qlji1hb8g9n3vn2cfcvjhf3iywdk98
zeus       qhm6kcpsxapv0jn341rqgvpsz7pmlnry
```

### Phase 3 — `lojix build` all 6 nodes (full toplevel realisation)

(In progress; this file gets updated as each completes.)

| node | status | notes |
|------|--------|-------|
| ouranos | RUNNING | started 01:19, 9 nixbld workers, deps fetching/building |
| klio | pending | |
| balboa | pending | |
| prometheus | pending | |
| tiger | pending | |
| zeus | pending | |

### Phase 4 — `nix flake check` per Rust crate

(Pending after toplevel builds.)

| repo | result |
|------|--------|
| lojix | pending |
| horizon-rs | pending |
| clavifaber | pending |
| brightness-ctl | pending |

## Issues encountered + fixes

1. **CriomOS-home niri-flake gate** ([CriomOS-home/modules/home/default.nix](../../CriomOS-home/modules/home/default.nix)):
   the `inputs != null` gate didn't check whether `niri-flake` was actually
   in the consumer's inputs. CriomOS doesn't declare niri-flake. Tightened
   to `inputs != null && inputs ? niri-flake`. Pushed.

2. **target/ in .gitignore** for clavifaber + brightness-ctl: jj kept
   warning about refused snapshot of cargo build artifacts. Added
   `/target/` entries. Pushed.

## Open questions for the morning

1. Did `lojix build` complete on all 6 nodes? See table above.
2. Did `nix flake check` pass on all 4 Rust crates?
3. Did anything break from nixpkgs jumping 4 days?
