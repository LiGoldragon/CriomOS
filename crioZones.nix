{ }

# Intentionally empty.
#
# Earlier design enumerated `crioZones.<cluster>.<node>.*` from any
# flake input that exposed a `NodeProposal` attr. That model is
# superseded.
#
# New model: CriomOS knows nothing about clusters. A separate Rust
# orchestrator tool (see /home/li/git/CriomOS/reports/2026-04-24-ractor-tool-design.md)
# projects goldragon's `datom.nota` via `horizon-cli --format json`,
# writes the resulting JSON into a generated wrapper flake, and
# invokes `nixos-rebuild` against that wrapper. The wrapper flake
# constructs the nixosSystem itself, passing `horizon` as a
# specialArg and including `inputs.criomos.nixosModules.criomos` as
# the platform module aggregate.
#
# CriomOS exposes:
#   - lib.mkHorizon         — JSON reader (lib/default.nix)
#   - nixosModules.criomos  — the platform module aggregate (auto-derived
#                             by blueprint from modules/nixos/criomos.nix)
#
# This file is kept as a tombstone so future readers find the design
# note instead of reaching for the old enumerate-clusters model.
