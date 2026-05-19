{
  lib,
  horizon,
  ...
}:
let
  inherit (horizon) node;
  nodeServices = import ../node-services.nix { inherit lib; };
  services = node.services or [ ];
in
{
  config = lib.mkIf (nodeServices.has services "TailnetClient") {
    # Phase 1 scaffolding only: enrollment remains manual.
    services.tailscale = {
      enable = true;
      openFirewall = true;
    };
  };
}
