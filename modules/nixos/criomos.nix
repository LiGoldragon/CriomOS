{ flake, inputs, ... }:

# nixosModules.criomos — top aggregate.

{ config, lib, horizon ? null, ... }:
{
  imports = [
    ./disks/preinstalled.nix
    ./normalize.nix
    ./nix.nix
    ./complex.nix
    ./llm.nix
    ./users.nix
    ./network/tailscale.nix
    ./network/networkd.nix
    ./network/yggdrasil.nix
  ];

  networking.hostName = horizon.node.name;
}
