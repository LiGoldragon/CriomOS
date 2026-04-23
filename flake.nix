{
  description = "CriomOS — network-neutral NixOS platform. Produces crioZones.<cluster>.<node>.* from any NodeProposal input.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";

    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Horizon schema + projection (Rust). Provides the `horizon-cli`
    # binary which CriomOS invokes via IFD in `lib.mkHorizon` to
    # project the goldragon cluster proposal for (cluster, node).
    horizon-rs.url = "github:LiGoldragon/horizon-rs";
    horizon-rs.inputs.nixpkgs.follows = "nixpkgs";

    # Home profile — its own repo, own inputs (niri, noctalia, stylix, emacs…).
    # CriomOS consumes homeModules.default and home-manager configures it.
    criomos-home.url = "github:LiGoldragon/CriomOS-home";
    criomos-home.inputs.nixpkgs.follows = "nixpkgs";
    criomos-home.inputs.home-manager.follows = "home-manager";

    # Backlight + idle-dim daemon. Consumed in modules/nixos/metal/.
    brightness-ctl.url = "github:LiGoldragon/brightness-ctl";
    brightness-ctl.inputs.nixpkgs.follows = "nixpkgs";

    # Cluster / NodeProposal inputs are NOT pinned here — they are declared
    # only by consumers (or by CI). A cluster is anything whose flake exposes
    # a `NodeProposal` attr. Example consumers declare:
    #   maisiliym.url = "github:LiGoldragon/maisiliym";
    # CriomOS discovers every such input at eval time via a custom
    # `crioZones` output layered on top of blueprint's standard outputs.
  };

  outputs =
    inputs:
    let
      blueprintOutputs = inputs.blueprint { inherit inputs; };
      crioZones = import ./crioZones.nix { inherit inputs; };
    in
    blueprintOutputs // { inherit crioZones; };
}
