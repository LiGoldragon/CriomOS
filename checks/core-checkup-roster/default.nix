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
  evaluated = evaluate {
    node = { name = "edge"; services = projectedServices; yggAddress = "200:db8::1"; };
    exNodes = { worker = { name = "worker"; yggAddress = "200:db8::2"; }; absent = { name = "absent"; }; };
  };
  text = evaluated.config.environment.etc."core-checkup/roster.json".text;
in
assert !baseline.config.services.coreCheckup.enable;
assert evaluated.config.services.coreCheckup.enable;
assert builtins.match ".*200:db8::1.*200:db8::2.*" text != null;
assert builtins.match ".*allowRestart.*false.*" text != null;
pkgs.runCommand "core-checkup-roster" { } "touch $out"
