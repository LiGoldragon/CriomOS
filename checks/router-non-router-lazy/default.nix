{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  horizonFor = router: {
    cluster = {
      name = "goldragon";
      tailnetBaseDomain = "tailnet.goldragon.criome";
    };
    node = {
      name = "router-laziness-fixture";
      behavesAs = { inherit router; };
    };
  };

  configurationFor = router:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        horizon = horizonFor router;
        inputs = inputs // { secrets = { sopsFiles = { }; }; };
        constants = inputs.criomos-lib.lib.constants;
      };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/router/default.nix
        { nixpkgs.config.allowUnfree = true; }
      ];
    };

  nonRouter = builtins.tryEval (configurationFor false).config.system.build.toplevel;
  routerWithoutInterfaces = builtins.tryEval (configurationFor true).config.system.build.toplevel;
in
assert lib.assertMsg nonRouter.success
  "non-router Horizon projections must not require routerInterfaces";
assert lib.assertMsg (!routerWithoutInterfaces.success)
  "router Horizon projections must still require routerInterfaces";
pkgs.runCommand "router-non-router-lazy-check" { } ''
  touch "$out"
''
