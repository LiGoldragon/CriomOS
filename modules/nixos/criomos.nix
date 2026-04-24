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
    ./network            # aggregator — pulls in unbound, yggdrasil, tailscale,
                         # headscale, nordvpn, wifi-eap, networkd, wireguard,
                         # plus networking.hosts entries from horizon.exNodes
    ./edge/default.nix
    ./userHomes.nix
    ./metal/default.nix
    ./router/default.nix
  ];
}
