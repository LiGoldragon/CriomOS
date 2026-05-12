{
  lib,
  horizon,
  ...
}:
let
  inherit (horizon) node;
  services = node.services or { };
in
{
  config = lib.mkIf ((services.tailnet or null) == "Client") {
    # Phase 1 scaffolding only: enrollment remains manual.
    services.tailscale = {
      enable = true;
      openFirewall = true;
    };
  };
}
