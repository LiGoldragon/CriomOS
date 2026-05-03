{ flake, inputs, ... }:

# nixosModules.criomos — top aggregate.

{
  lib,
  deployment ? {
    includeHome = true;
  },
  ...
}:
let
  includeHome = deployment.includeHome or true;
in
{
  imports = [
    ./disks/preinstalled.nix
    ./normalize.nix
    ./nix.nix
    ./lojix-input-archive.nix
    ./complex.nix
    ./llm.nix
    ./users.nix
    ./network
    # aggregator — pulls in unbound, yggdrasil, tailscale,
    # headscale, nordvpn, wifi-eap, networkd, wireguard,
    # plus networking.hosts entries from horizon.exNodes
    ./edge/default.nix
  ]
  ++ lib.optionals includeHome [
    ./userHomes.nix
  ]
  ++ [
    ./metal/default.nix
    ./router/default.nix
  ];

  # dconf-service is enabled cluster-wide so the system D-Bus always
  # has `ca.desrt.dconf` registered. home-manager's dconfSettings
  # activation (which stylix populates regardless of host role) then
  # succeeds on every node; on headless boxes the keys are written
  # but unread (no GTK/portal app reads them). The marginal cost is
  # one small daemon — cheaper than duplicating the headless-vs-edge
  # predicate on both system and home sides.
  programs.dconf.enable = true;
}
