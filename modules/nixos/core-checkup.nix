{ lib, horizon, ... }:
let
  inherit (lib) mkOption types;
  rosterProjection = import ./core-checkup-roster.nix { inherit lib horizon; };
in {
  options.services.coreCheckup = {
    enable = mkOption { type = types.bool; default = false; };
    roster = mkOption { type = types.str; readOnly = true; };
  };
  config = lib.mkIf rosterProjection.enabled {
    services.coreCheckup.enable = true;
    environment.etc."core-checkup/roster.json".text = builtins.toJSON rosterProjection.roster;
    services.coreCheckup.roster = "/etc/core-checkup/roster.json";
  };
}
