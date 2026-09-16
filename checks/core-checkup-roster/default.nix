{ pkgs, lib, ... }:
let
  evaluate = horizon: import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
    ../../modules/nixos/core-checkup.nix
      { _module.args.horizon = horizon; system.stateVersion = "26.11"; }
    ];
  };
  # Exact services array emitted by horizon-cli for the isolated Ouranos proposal.
  # The matching proposal is goldragon:proposal/cf7879-core-checkup-ouranos.
  projectedServices = builtins.fromJSON (builtins.readFile ./ouranos-services.json);
  baseline = evaluate { node = { name = "edge"; services = [ ]; yggAddress = "200:db8::1"; }; exNodes = { }; };
  selectedHorizon = {
    node = { name = "edge"; services = projectedServices; yggAddress = "200:db8::1"; };
    exNodes = { worker = { name = "worker"; yggAddress = "200:db8::2"; }; absent = { name = "absent"; }; };
  };
  evaluated = evaluate selectedHorizon;
  artifact = pkgs.callPackage ../../artifacts/core-checkup-roster.nix { horizon = selectedHorizon; };
  text = evaluated.config.environment.etc."core-checkup/roster.json".text;
  roster = builtins.fromJSON text;
in
assert !baseline.config.services.coreCheckup.enable;
assert evaluated.config.services.coreCheckup.enable;
assert builtins.match ".*200:db8::1.*200:db8::2.*" text != null;
assert roster.allowRestart == false;
assert !(roster ? allowRepair);
assert text == builtins.readFile artifact;
assert builtins.length roster.units == 4;
assert builtins.all (unit: unit.allowRestart == false) roster.units;
pkgs.runCommand "core-checkup-roster" { } "touch $out"
