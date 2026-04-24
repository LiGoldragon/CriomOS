{ flake, inputs, ... }:

# nixosModules.criomos — top aggregate.

{ config, lib, horizon ? null, ... }:
{
  imports = [
    ./disks/preinstalled.nix
  ];

  networking.hostName = horizon.node.name;

  # Pin to the nixpkgs release that the pkgs-flake was instantiated
  # against. Will become a CriomOS-level enum (bleeding-edge / stable
  # / testing) once we abstract the nixpkgs revs.
  system.stateVersion = "26.05";
}
