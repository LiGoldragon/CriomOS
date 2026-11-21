# Cargo for iteration (Fable ruling bwv8). The builder carries a real Cargo,
# build-base's toolchain, for iteration in a work tree of the synchronized
# folder; every other host keeps the remote-only wrapper. The host is the one
# that receives the cluster's builds (horizon: isRemoteNixBuilder on a center
# node), so CriomOS names no node. Each user's Home on the host takes it
# (userHomes.nix); the Home holds the toolchain and the target directory
# (CriomOS-home modules/home/profiles/min/rust-iteration.nix).
{ lib, horizon, ... }:
let
  node = horizon.node;
  receivesBuilds = (node.isRemoteNixBuilder or false) && (node.behavesAs.center or false);
in
{
  options.criomos.rustIteration.enable = lib.mkOption {
    type = lib.types.bool;
    default = receivesBuilds;
    defaultText = lib.literalExpression "horizon.node.isRemoteNixBuilder && horizon.node.behavesAs.center";
    description = "Give every user's Home on this host a real Cargo for iteration in place of the remote-only wrapper.";
  };
}
