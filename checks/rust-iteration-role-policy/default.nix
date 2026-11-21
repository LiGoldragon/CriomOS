{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  systemFor =
    node: extraModules:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = { inherit node; };
      };
      modules = [
        ../../modules/nixos/rust-iteration.nix
        { system.stateVersion = "26.05"; }
      ]
      ++ extraModules;
    }).config;

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

  builder = systemFor builderNode [ ];
  disabledBuilder = systemFor builderNode [ { criomos.rustIteration.enable = false; } ];
  edgeBuilder = systemFor edgeBuilderNode [ ];
  laptop = systemFor laptopNode [ ];
  carrying = homeFor true;
  wrapped = homeFor false;
  baseToolchain = inputs.criomos-home.inputs.base.packages.${system}.toolchain;
  wrapper = inputs.criomos-home.packages.${system}.rust-toolchain;
in
assert builder.criomos.rustIteration.enable;
assert builtins.elem baseToolchain builder.environment.systemPackages;
assert builtins.all
  (
    host:
    !host.criomos.rustIteration.enable && !(builtins.elem baseToolchain host.environment.systemPackages)
  )
  [
    disabledBuilder
    edgeBuilder
    laptop
  ];
assert carrying.criomosHome.rustIteration.toolchain == null;
assert wrapped.criomosHome.rustIteration.toolchain == wrapper;
assert lib.hasInfix ''target-dir = "/home/example/.cache/cargo-iteration"''
  carrying.home.file.".cargo/config.toml".text;
assert !(wrapped.home.file ? ".cargo/config.toml");
pkgs.runCommand "rust-iteration-role-policy" { } ''
  ${builder.system.path}/bin/cargo --version
  ${builder.system.path}/bin/rustc --version
  status=0
  ${wrapped.criomosHome.rustIteration.toolchain}/bin/cargo --version 2>reply || status=$?
  test "$status" -eq 126
  touch "$out"
''
