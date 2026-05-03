{
  description = "CriomOS — NixOS platform consuming content-addressed flake inputs from lojix: `system` (the target tuple), `pkgs` (a stable wrapper flake that imports nixpkgs for that system), `horizon` (the per-deploy projected horizon JSON), and `deployment` (operation shape such as home-enabled vs home-off). Each axis caches independently in nix's flake-eval cache: pkgs eval is reused across deploys with the same system; horizon/deployment changes don't touch pkgs.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs?ref=nixos-unstable";

    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Shared constants, helpers, and cross-repo data. Consumed by both
    # CriomOS and CriomOS-home.
    criomos-lib.url = "github:LiGoldragon/CriomOS-lib";

    # Home profile — its own repo, own inputs (niri, noctalia, stylix, emacs…).
    criomos-home.url = "github:LiGoldragon/CriomOS-home";
    criomos-home.inputs.nixpkgs.follows = "nixpkgs";
    criomos-home.inputs.home-manager.follows = "home-manager";
    criomos-home.inputs.criomos-lib.follows = "criomos-lib";

    # Backlight + idle-dim daemon. Consumed in modules/nixos/metal/.
    brightness-ctl.url = "github:LiGoldragon/brightness-ctl";
    brightness-ctl.inputs.nixpkgs.follows = "nixpkgs";

    # GPG → X.509 cert tool for WiFi PKI + node identity complex.
    # Consumed in modules/nixos/complex.nix.
    clavifaber.url = "github:LiGoldragon/clavifaber";
    clavifaber.inputs.nixpkgs.follows = "nixpkgs";

    # System tuple — lojix produces a tiny content-addressed flake
    # whose only output is `system = "x86_64-linux"` (or aarch64).
    system.url = "path:./stubs/no-system";

    # Pkgs flake — instantiates nixpkgs for the given (nixpkgs-rev,
    # system) tuple, plus our overlays. Its own repo so CriomOS source
    # edits don't invalidate the pkgs eval cache (root-flake-keyed).
    # nixpkgs + system propagate via `follows` so the pkgs flake sees
    # the same revisions CriomOS does.
    pkgs.url = "github:LiGoldragon/CriomOS-pkgs";
    pkgs.inputs.nixpkgs.follows = "nixpkgs";
    pkgs.inputs.system.follows = "system";

    # Horizon — the projected (cluster, node) view. lojix overrides
    # per deploy.
    horizon.url = "path:./stubs/no-horizon";

    # Deployment shape — lojix overrides per request. The default keeps
    # the historical full system+home target.
    deployment.url = "path:./stubs/default-deployment";
  };

  outputs =
    inputs:
    let
      blueprintOutputs = inputs.blueprint { inherit inputs; };

      horizon = inputs.horizon.horizon;
      pkgs = inputs.pkgs.pkgs;
      system = inputs.system.system;
      deployment = inputs.deployment.deployment or { includeHome = true; };
      includeHome = deployment.includeHome or true;

      criomos-lib = inputs.criomos-lib.lib;
      constants = criomos-lib.constants;

      target = inputs.nixpkgs.lib.nixosSystem {
        # `system` is derived from `pkgs.stdenv.hostPlatform.system`
        # when `pkgs` is supplied; passing it explicitly would set
        # `nixpkgs.system`, which `readOnlyPkgs` has removed.
        inherit pkgs;
        specialArgs = {
          inherit
            horizon
            system
            deployment
            inputs
            constants
            criomos-lib
            ;
        };
        modules = [
          inputs.nixpkgs.nixosModules.readOnlyPkgs
        ]
        ++ inputs.nixpkgs.lib.optionals includeHome [
          inputs.home-manager.nixosModules.home-manager
        ]
        ++ [
          inputs.self.nixosModules.criomos
        ];
      };
    in
    blueprintOutputs
    // {
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
