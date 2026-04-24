{
  description = "CriomOS — NixOS platform consuming three content-addressed flake inputs from lojix: `system` (the target tuple), `pkgs` (a stable wrapper flake that imports nixpkgs for that system), and `horizon` (the per-deploy projected horizon JSON). Each axis caches independently in nix's flake-eval cache: pkgs eval is reused across deploys with the same system, horizon changes don't touch pkgs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";

    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Home profile — its own repo, own inputs (niri, noctalia, stylix, emacs…).
    criomos-home.url = "github:LiGoldragon/CriomOS-home";
    criomos-home.inputs.nixpkgs.follows = "nixpkgs";
    criomos-home.inputs.home-manager.follows = "home-manager";

    # Backlight + idle-dim daemon. Consumed in modules/nixos/metal/.
    brightness-ctl.url = "github:LiGoldragon/brightness-ctl";
    brightness-ctl.inputs.nixpkgs.follows = "nixpkgs";

    # System tuple — lojix produces a tiny content-addressed flake
    # whose only output is `system = "x86_64-linux"` (or aarch64).
    system.url = "path:./stubs/no-system";

    # Pkgs flake — instantiates nixpkgs for the given (nixpkgs-rev,
    # system) tuple. Lives in this repo at ./pkgs-flake; consumed via
    # path: so its eval cache is keyed independently. nixpkgs and
    # system are propagated via `follows`, so the pkgs flake sees
    # the same revisions CriomOS does without having to be regenerated.
    pkgs.url = "path:./pkgs-flake";
    pkgs.inputs.nixpkgs.follows = "nixpkgs";
    pkgs.inputs.system.follows = "system";

    # Horizon — the projected (cluster, node) view. lojix overrides
    # per deploy.
    horizon.url = "path:./stubs/no-horizon";
  };

  outputs =
    inputs:
    let
      blueprintOutputs = inputs.blueprint { inherit inputs; };

      horizon = inputs.horizon.horizon;
      pkgs    = inputs.pkgs.pkgs;
      system  = inputs.system.system;

      constants = import ./modules/nixos/constants.nix;
      criomos-lib = import ./lib { };

      target = inputs.nixpkgs.lib.nixosSystem {
        # `system` is derived from `pkgs.stdenv.hostPlatform.system`
        # when `pkgs` is supplied; passing it explicitly would set
        # `nixpkgs.system`, which `readOnlyPkgs` has removed.
        inherit pkgs;
        specialArgs = {
          inherit horizon system inputs constants criomos-lib;
        };
        modules = [
          inputs.nixpkgs.nixosModules.readOnlyPkgs
          inputs.self.nixosModules.criomos
        ];
      };
    in
    blueprintOutputs // {
      nixosConfigurations.target = target;

      # For cache-property testing — exposes the parsed horizon
      # without going through nixosSystem evaluation.
      horizonProbe = horizon;

      # Likewise for the pkgs axis — cheap probe that forces a
      # pkgs evaluation through the pkgs-flake input. Same `system`
      # input → cached across deploys.
      pkgsProbe = pkgs.stdenv.hostPlatform.system;
    };
}
