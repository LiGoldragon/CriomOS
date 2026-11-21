{ config, lib, pkgs, horizon, ... }:
let
  node = horizon.node.name;
  takesPart = synchronization: synchronization.master == node || synchronization.replica == node;
  isReplica = builtins.any (
    user: builtins.any (synchronization: synchronization.replica == node) user.synchronizations
  ) horizon.users;
  # Each tree this node holds, as master or replica, is a directory its user
  # owns before Unison watches it: the replica's watcher refuses a missing root.
  roots = lib.concatMap (
    user:
    let
      account = config.users.users.${user.name};
    in
    map (synchronization: {
      name = "${account.home}/${synchronization.tree}";
      value.d = {
        user = account.name;
        inherit (account) group;
      };
    }) (builtins.filter takesPart user.synchronizations)
  ) horizon.users;
in
{
  options.criomos.unisonReplica.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.unison;
    description = "Unison program called over SSH when this node is a synchronization replica.";
  };
  config = lib.mkMerge [
    (lib.mkIf isReplica {
      environment.systemPackages = [ config.criomos.unisonReplica.package ];
    })
    (lib.mkIf (roots != [ ]) {
      systemd.tmpfiles.settings.unison-roots = builtins.listToAttrs roots;
    })
  ];
}
