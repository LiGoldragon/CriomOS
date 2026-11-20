{ pkgs }:
let
  inherit (pkgs) lib;
  evaluate = node: (lib.evalModules {
    specialArgs.horizon = { inherit node; };
    modules = [
      ../../modules/nixos/battery-power-policy.nix
      ({ lib, ... }: {
        options.services.upower = lib.mkOption { type = lib.types.attrs; default = {}; };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      })
    ];
  }).config;
  policy = { low = 20; critical = 10; action = 5; criticalPowerAction = "HybridSleep"; };
  configured = evaluate { batteryPowerPolicy = policy; };
  absent = evaluate {};
  invalid = evaluate { batteryPowerPolicy = policy // { critical = 5; }; };
in
assert configured.services.upower == {
  enable = true;
  usePercentageForPolicy = true;
  percentageLow = 20;
  percentageCritical = 10;
  percentageAction = 5;
  criticalPowerAction = "HybridSleep";
};
assert builtins.all (entry: entry.assertion) configured.assertions;
assert absent.services.upower == {};
assert absent.assertions == [];
assert !(builtins.all (entry: entry.assertion) invalid.assertions);
pkgs.runCommand "battery-power-policy-contract" {} ''
  touch "$out"
''
