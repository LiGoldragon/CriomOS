{
  lib,
  horizon,
  ...
}:
let
  inherit (builtins) elem;
  inherit (horizon) node;

  isTailnetNode = elem node.name [ "ouranos" "prometheus" ];
in
{
  config = lib.mkIf isTailnetNode {
    # Phase 1 scaffolding only: enrollment remains manual.
    services.tailscale = {
      enable = true;
      openFirewall = true;
    };
  };
}
