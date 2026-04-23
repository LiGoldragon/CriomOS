{ flake, inputs, ... }:

# nixosModules.criomos — top aggregate.
#
# Empty on purpose. Split modules will be imported here as they land:
#   ./normalize.nix
#   ./nix.nix
#   ./complex.nix
#   ./users.nix
#   ./metal
#   ./edge.nix
#   ./router
#   ./llm.nix
#   ./network
#   ./disks
#
# Consuming hosts do `imports = [ flake.nixosModules.criomos ];` and pass
# `horizon` via `_module.args`.

{ config, lib, horizon ? null, ... }:
{
  imports = [ ];

  config = { };
}
