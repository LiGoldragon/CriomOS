# Build-base's iteration toolchain belongs to the host that receives builds.
{
  config,
  horizon,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  node = horizon.node;
  receivesBuilds = (node.isRemoteNixBuilder or false) && (node.behavesAs.center or false);
  system = pkgs.stdenv.hostPlatform.system;
  cfg = config.criomos.rustIteration;
  baseToolchain = inputs.criomos-home.inputs.base.packages.${system}.toolchain;

  iterationCargo = pkgs.writeShellScript "iteration-cargo" ''
    if [[ ! -v CARGO_TARGET_DIR && ! -v CARGO_BUILD_TARGET_DIR ]]; then
      export CARGO_TARGET_DIR="''${HOME:?}"/${lib.escapeShellArg cfg.targetDirectory}
    fi
    exec ${baseToolchain}/bin/cargo "$@"
  '';
  iterationToolchain = pkgs.symlinkJoin {
    name = "rust-iteration-toolchain";
    paths = [ baseToolchain ];
    postBuild = ''
      rm "$out/bin/cargo"
      ln -s ${iterationCargo} "$out/bin/cargo"
    '';
  };
in
{
  options.criomos.rustIteration = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = receivesBuilds;
      defaultText = lib.literalExpression "horizon.node.isRemoteNixBuilder && horizon.node.behavesAs.center";
      description = "Provide build-base's Rust iteration toolchain in the host's system profile.";
    };
    targetDirectory = lib.mkOption {
      type = lib.types.addCheck lib.types.str (
        path:
        builtins.all (
          component:
          !builtins.elem component [
            ""
            "."
            ".."
          ]
        ) (lib.splitString "/" path)
      );
      default = ".cache/cargo-iteration";
      description = "Home-relative default output directory for system Cargo. An explicit Cargo target environment variable or command-line option takes precedence.";
    };
  };

  config.environment.systemPackages = lib.mkIf cfg.enable [ iterationToolchain ];
}
