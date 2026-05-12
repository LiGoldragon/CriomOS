{
  lib,
  horizon,
  ...
}:
let
  inherit (horizon) node;
in
{
  config = lib.mkIf (node.tailnetClient or false) {
    # Phase 1 scaffolding only: enrollment remains manual.
    services.tailscale = {
      enable = true;
      openFirewall = true;
    };
  };
}
