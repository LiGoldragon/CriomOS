{ pkgs, lib ? pkgs.lib, horizon }:
let
  projection = import ../modules/nixos/core-checkup-roster.nix { inherit lib horizon; };
in
if !projection.enabled then
  throw "core-checkup-roster requires the typed Horizon CoreCheckup service"
else
  pkgs.writeText "core-checkup-roster.json" (builtins.toJSON projection.roster)
