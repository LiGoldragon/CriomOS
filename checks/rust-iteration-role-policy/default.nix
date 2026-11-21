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
  customBuilder = systemFor builderNode [
    { criomos.rustIteration.targetDirectory = ".cache/custom iteration"; }
  ];
  disabledBuilder = systemFor builderNode [ { criomos.rustIteration.enable = false; } ];
  edgeBuilder = systemFor edgeBuilderNode [ ];
  laptop = systemFor laptopNode [ ];
  carrying = homeFor true;
  wrapped = homeFor false;
  baseToolchain = inputs.criomos-home.inputs.base.packages.${system}.toolchain;
  wrapper = inputs.criomos-home.packages.${system}.rust-toolchain;
in
assert builder.criomos.rustIteration.enable;
assert builtins.all (host: !host.criomos.rustIteration.enable) [
  disabledBuilder
  edgeBuilder
  laptop
];
assert carrying.criomosHome.rustIteration.toolchain == null;
assert wrapped.criomosHome.rustIteration.toolchain == wrapper;
assert !(carrying.home.file ? ".cargo/config.toml");
assert !(wrapped.home.file ? ".cargo/config.toml");
pkgs.runCommand "rust-iteration-role-policy"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.stdenv.cc
    ];
  }
  ''
    export PATH="${builder.system.path}/bin:$PATH"
    export HOME="$TMPDIR/home"
    export CARGO_HOME="$TMPDIR/cargo-home"
    unset CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR

    for profile in ${disabledBuilder.system.path} ${edgeBuilder.system.path} ${laptop.system.path}; do
      test ! -e "$profile/bin/cargo"
      test ! -e "$profile/bin/rustc"
    done

    builder_cargo=${builder.system.path}/bin/cargo
    custom_cargo=${customBuilder.system.path}/bin/cargo
    "$builder_cargo" --version
    test "$(readlink -f ${builder.system.path}/bin/rustc)" = "$(readlink -f ${baseToolchain}/bin/rustc)"
    ${builder.system.path}/bin/rustc --version

    mkdir -p "$HOME/Code/fixture/src" "$CARGO_HOME" "$TMPDIR/another-home"
    cd "$HOME/Code/fixture"
    cat > Cargo.toml <<'MANIFEST'
    [package]
    name = "iteration-fixture"
    version = "0.0.0"
    edition = "2021"
    MANIFEST
    echo 'fn main() {}' > src/main.rs
    target_directory() {
      "$1" metadata --offline --no-deps --format-version 1 | jq -er .target_directory
    }

    "$builder_cargo" build --offline
    test -x "$HOME/.cache/cargo-iteration/debug/iteration-fixture"
    test ! -e target
    test "$(target_directory "$builder_cargo")" = "$HOME/.cache/cargo-iteration"
    test "$(HOME="$TMPDIR/another-home" target_directory "$builder_cargo")" = "$TMPDIR/another-home/.cache/cargo-iteration"
    test "$(target_directory "$custom_cargo")" = "$HOME/.cache/custom iteration"
    test "$(CARGO_TARGET_DIR="$TMPDIR/target-override" target_directory "$builder_cargo")" = "$TMPDIR/target-override"
    test "$(CARGO_BUILD_TARGET_DIR="$TMPDIR/build-override" target_directory "$builder_cargo")" = "$TMPDIR/build-override"

    status=0
    ${wrapped.criomosHome.rustIteration.toolchain}/bin/cargo --version 2>reply || status=$?
    test "$status" -eq 126
    touch "$out"
  ''
