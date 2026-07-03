{
  horizon,
  inputs,
  constants,
  lib,
  ...
}:
let
  inherit (builtins) mapAttrs;

  mkUserConfig = _name: user: {
    _module.args = {
      inherit user;
    };
    home.stateVersion = "26.05";
  };

  # Deploy a user's home ONLY on nodes where that user has a presence — i.e. a
  # per-node pub-key entry for THIS viewpoint node (`hasPubKey`). `horizon.users`
  # is the FULL cluster user set (every node's projection lists all users, for
  # identity/keys/trust — e.g. both prometheus and ouranos list `bird` even
  # though `bird`'s home-nodes are only tiger/zeus). A user's HOME belongs only
  # on the nodes their per-node `pub_keys` map names. Without this filter every
  # node built every user's home (prometheus built `bird`'s home though `bird`
  # has no key there), dragging in unrelated home closures — and any orphaned
  # dep in one of those homes (e.g. a force-pushed git rev) fails the whole
  # node's eval even where that home does not belong.
  homeUsers = lib.filterAttrs (_name: user: user.hasPubKey) horizon.users;

in
{
  home-manager = {
    backupFileExtension = "backup";
    # `inputs` deliberately NOT in extraSpecialArgs — CriomOS-home's
    # homeModules.default wrapper sets _module.args.inputs to
    # CriomOS-home's own flake inputs (which is what its modules need;
    # see CriomOS-home/flake.nix). Passing CriomOS's `inputs` here
    # would shadow that via specialArgs precedence.
    extraSpecialArgs = {
      inherit horizon constants;
    };
    sharedModules = [ inputs.criomos-home.homeModules.default ];
    useGlobalPkgs = true;
    users = mapAttrs mkUserConfig homeUsers;
  };
}
