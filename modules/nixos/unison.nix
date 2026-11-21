{ config, lib, pkgs, horizon, ... }:
let
  isReplica = builtins.any (
    user: builtins.any (synchronization: synchronization.replica == horizon.node.name) user.synchronizations
  ) horizon.users;
in
{
  options.criomos.unisonReplica.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.unison;
    description = "Unison program called over SSH when this node is a synchronization replica.";
  };
  config = lib.mkIf isReplica {
    environment.systemPackages = [ config.criomos.unisonReplica.package ];
  };
}
