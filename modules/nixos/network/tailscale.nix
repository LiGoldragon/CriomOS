{
  lib,
  horizon,
  ...
}:
let
  inherit (horizon) node;
  nodeServices = import ../node-services.nix { inherit lib; };
in
{
  config = lib.mkIf (nodeServices.has (node.services or [ ]) "TailnetClient") {
    # Phase 1 scaffolding only: enrollment remains manual.
    services.tailscale = {
      enable = true;
      openFirewall = true;
    };
  };
}
