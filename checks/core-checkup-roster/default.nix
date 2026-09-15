{ pkgs, lib, ... }:
let
  evaluated = lib.evalModules { modules = [ ../../modules/nixos/core-checkup.nix { horizon = { node = { name = "edge"; coreCheckup = true; yggAddress = "200:db8::1"; }; exNodes = { worker = { name = "worker"; yggAddress = "200:db8::2"; }; absent = { name = "absent"; }; }; }; } ]; };
  text = evaluated.config.environment.etc."core-checkup/roster.json".text;
in
assert evaluated.config.services.coreCheckup.enable;
assert builtins.match ".*200:db8::1.*200:db8::2.*" text != null;
assert builtins.match ".*allowRestart.*false.*" text != null;
pkgs.runCommand "core-checkup-roster" { } "touch $out"
