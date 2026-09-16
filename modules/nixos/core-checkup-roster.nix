{ lib, horizon }:
let
  nodeServices = import ./node-services.nix { inherit lib; };
  services = nodeServices.of horizon.node;
  enabled = nodeServices.has services "coreCheckup";
  allNodes = [ horizon.node ] ++ lib.attrValues (horizon.exNodes or { });
  addressOf = node: node.yggAddress or (node.yggdrasil.address or null);
  reachableNodes = lib.filter (node: addressOf node != null) allNodes;
in
{
  inherit enabled;
  roster = {
    endpoints = map (node: { name = node.name; address = addressOf node; }) reachableNodes;
    # These are the pre-existing OS-selected targets. The typed CoreCheckup
    # service enables the roster; it does not manufacture a unit target or
    # grant restart permission.
    units = [
      { name = "orchestrate-nexus.service"; scope = "user"; owned = true; allowRestart = false; }
      { name = "message-daemon.service"; scope = "user"; owned = true; allowRestart = false; }
      { name = "codex-remote-control.service"; scope = "user"; owned = true; allowRestart = false; }
      { name = "lojix.service"; scope = "system"; owned = false; allowRestart = false; }
    ];
    allowRestart = false;
  };
}
