{ lib, horizon, ... }:
let
  inherit (lib) attrValues filter mkOption types;
  allNodes = [ horizon.node ] ++ attrValues (horizon.exNodes or { });
  addressOf = node: node.yggAddress or (node.yggdrasil.address or null);
  reachableNodes = filter (node: addressOf node != null) allNodes;
in {
  options.services.coreCheckup = {
    enable = mkOption { type = types.bool; default = false; };
    roster = mkOption { type = types.str; readOnly = true; };
  };
  config = lib.mkIf (horizon.node.coreCheckup or false) {
    services.coreCheckup.enable = true;
    environment.etc."core-checkup/roster.json".text = builtins.toJSON {
      endpoints = map (node: { name = node.name; address = addressOf node; }) reachableNodes;
      units = [
        { name = "orchestrate-nexus.service"; scope = "user"; owned = true; allowRestart = false; }
        { name = "message-daemon.service"; scope = "user"; owned = true; allowRestart = false; }
        { name = "codex-remote-control.service"; scope = "user"; owned = true; allowRestart = false; }
        { name = "lojix.service"; scope = "system"; owned = false; allowRestart = false; }
      ];
      allowRepair = false;
    };
    services.coreCheckup.roster = "/etc/core-checkup/roster.json";
  };
}
