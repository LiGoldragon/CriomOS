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
in
{
  options.criomos.rustIteration.enable = lib.mkOption {
    type = lib.types.bool;
    default = receivesBuilds;
    defaultText = lib.literalExpression "horizon.node.isRemoteNixBuilder && horizon.node.behavesAs.center";
    description = "Provide build-base's Rust iteration toolchain in the host's system profile.";
  };

  config.environment.systemPackages = lib.mkIf config.criomos.rustIteration.enable [
    inputs.criomos-home.inputs.base.packages.${system}.toolchain
  ];
}
