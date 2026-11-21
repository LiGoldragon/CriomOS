# Cargo for iteration (Fable ruling bwv8): the host that receives the
# cluster's builds carries build-base's real Cargo with its target directory;
# every other host keeps the remote-only wrapper.
{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  enabledFor =
    node:
    (lib.evalModules {
      specialArgs.horizon = { inherit node; };
      modules = [ ../../modules/nixos/rust-iteration.nix ];
    }).config.criomos.rustIteration.enable;

  builderNode = {
    isRemoteNixBuilder = true;
    behavesAs.center = true;
  };
  edgeBuilderNode = builderNode // {
    behavesAs.center = false;
  };
  laptopNode = {
    isRemoteNixBuilder = false;
    behavesAs.center = false;
  };

  homeFor =
    enable:
    (inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inputs = inputs.criomos-home.inputs;
        rustToolchain = inputs.criomos-home.packages.${system}.rust-toolchain;
      };
      modules = [
        "${inputs.criomos-home}/modules/home/profiles/min/rust-iteration.nix"
        {
          home.username = "example";
          home.homeDirectory = "/home/example";
          home.stateVersion = "26.05";
          criomosHome.rustIteration.enable = enable;
        }
      ];
    }).config;

  carrying = homeFor true;
  wrapped = homeFor false;
  baseToolchain = inputs.criomos-home.inputs.base.packages.${system}.toolchain;
  wrapper = inputs.criomos-home.packages.${system}.rust-toolchain;
in
assert enabledFor builderNode;
assert !(enabledFor edgeBuilderNode);
assert !(enabledFor laptopNode);
assert carrying.criomosHome.rustIteration.toolchain == baseToolchain;
assert wrapped.criomosHome.rustIteration.toolchain == wrapper;
assert lib.hasInfix ''target-dir = "/home/example/.cache/cargo-iteration"''
  carrying.home.file.".cargo/config.toml".text;
assert !(wrapped.home.file ? ".cargo/config.toml");
pkgs.runCommand "rust-iteration-role-policy" { } ''
  ${carrying.criomosHome.rustIteration.toolchain}/bin/cargo --version
  ${carrying.criomosHome.rustIteration.toolchain}/bin/rustc --version
  status=0
  ${wrapped.criomosHome.rustIteration.toolchain}/bin/cargo --version 2>reply || status=$?
  test "$status" -eq 126
  touch "$out"
''
