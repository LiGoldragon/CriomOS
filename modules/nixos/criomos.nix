{ flake, inputs, ... }:

# nixosModules.criomos — top aggregate.

{ config, lib, horizon ? null, ... }:
{
  imports = [
    ./disks/preinstalled.nix
    ./normalize.nix
    ./nix.nix
  ];

  networking.hostName = horizon.node.name;
}
