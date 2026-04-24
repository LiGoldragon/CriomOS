{
  description = "CriomOS — NixOS platform consuming a single (cluster, node) horizon as a content-addressed flake input. The orchestrator (lojix) produces the horizon and overrides this input; nix's eval/build cache hits across runs whenever the horizon content is identical.";

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

    # Horizon — the projected (cluster, node) view. Default stub
    # throws on access; lojix overrides at deploy time. Same content
    # → same store path → eval/build cache hits.
    horizon.url = "path:./stubs/no-horizon";
  };

  outputs =
    inputs:
    let
      blueprintOutputs = inputs.blueprint { inherit inputs; };

      horizon = inputs.horizon.horizon;

      systemFor = horizonSystem:
        {
          X86_64Linux  = "x86_64-linux";
          Aarch64Linux = "aarch64-linux";
        }.${horizonSystem};

      target = inputs.nixpkgs.lib.nixosSystem {
        system = systemFor horizon.node.system;
        specialArgs = { inherit horizon; };
        modules = [ inputs.self.nixosModules.criomos ];
      };
    in
    blueprintOutputs // {
      nixosConfigurations.target = target;

      # For cache-property testing — exposes the parsed horizon
      # without going through nixosSystem evaluation. Same horizon
      # input → same value → eval cache hit.
      horizonProbe = horizon;
    };
}
