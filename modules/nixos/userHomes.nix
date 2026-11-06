{
  horizon,
  inputs,
  constants,
  lib,
  pkgs,
  ...
}:
let
  inherit (builtins) mapAttrs;

  usersByName = inputs.criomos-home.horizonUsersByName horizon.users;

  mkUserConfig = name: user: { lib, osConfig, ... }: {
    _module.args = {
      inherit user;
    };
    home.stateVersion = "26.05";
    # The deployed Home activation package runs directly, outside the NixOS
    # home-manager service environment. Carry the consumer's backup policy
    # into that activation DAG so collision handling remains managed.
    home.activation = lib.optionalAttrs (osConfig.home-manager.backupFileExtension != null) {
      exportBackupFileExtension = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        export HOME_MANAGER_BACKUP_EXT=${lib.escapeShellArg osConfig.home-manager.backupFileExtension}
      '';
    };
    # What a user runs on this node is the capability vector of its key here.
    criomosHome.curriculum.enable = builtins.elem "AgentStack" user.capabilities;
    criomosHome.codexNextCandidate.enable = builtins.elem "CodexCandidate" user.capabilities;
  };

  # Deploy a user's home ONLY on nodes where that user has a presence — i.e. a
  # per-node public-key entry for THIS viewpoint node (`hasPublicKey`). `horizon.users`
  # is the FULL cluster user set (every node's projection lists all users, for
  # identity/keys/trust — e.g. both prometheus and ouranos list `bird` even
  # though `bird`'s home-nodes are only tiger/zeus). A user's HOME belongs only
  # on the nodes their per-node `pub_keys` map names. Without this filter every
  # node built every user's home (prometheus built `bird`'s home though `bird`
  # has no key there), dragging in unrelated home closures — and any orphaned
  # dep in one of those homes (e.g. a force-pushed git rev) fails the whole
  # node's eval even where that home does not belong.
  homeUsers = lib.filterAttrs (_name: user: user.hasPublicKey) usersByName;

in
{
  # A Home profile installation on a slow disk runs past the upstream
  # five-minute activation deadline; the allowance is bounded.
  systemd.services = lib.mapAttrs' (name: _: lib.nameValuePair "home-manager-${name}" {
    serviceConfig.TimeoutStartSec = lib.mkForce "20min";
  }) homeUsers;

  home-manager = {
    backupFileExtension = "backup";
    # `inputs` deliberately NOT in extraSpecialArgs — CriomOS-home's
    # homeModules.default wrapper sets _module.args.inputs to
    # CriomOS-home's own flake inputs (which is what its modules need;
    # see CriomOS-home/flake.nix). Passing CriomOS's `inputs` here
    # would shadow that via specialArgs precedence.
    extraSpecialArgs = {
      # `pkgs` is the exact package set that CriomOS-home used to construct its
      # standalone output.  Passing it directly preserves the embedded Home
      # activation package identity.
      inherit horizon constants pkgs;
      homeSystem = pkgs.stdenv.hostPlatform.system;
    };
    sharedModules = [ inputs.criomos-home.homeModules.default ];
    useGlobalPkgs = true;
    users = mapAttrs mkUserConfig homeUsers;
  };
}
