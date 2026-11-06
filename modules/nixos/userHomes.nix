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

  zeusRecordedHomeAdoption = {
  bird = {
    predecessorGeneration = {
      homeFiles = "/nix/store/gkk32mwcbr7sm41r1naqwzcr0hyxy6v8-home-manager-files";
      herdrConfig = "/nix/store/38s7v7pirbbgg9vmlwi7mv4ffi2r4sip-herdr-config.toml";
      herdrConfigSha256 = "ef01d6d652d02c8535fedb7be93c9a837d1f06e8da5da1a813fbd67e93f765cc";
    };
    kvantumDanglingLink = {
      literalTarget = "/nix/store/hm19bndn5aicvhmcr6a9m4x10i3871hl-home-manager-files/.config/Kvantum/Base16Kvantum";
    };
  };
  li = {
    predecessorGeneration = {
      homeFiles = "/nix/store/xqqj07nc68jg6nja4gliklmmk6yccmfm-home-manager-files";
      herdrConfig = "/nix/store/grj6d8lyx4z5wcfq9bh78mxs8hsz6p2i-herdr-config.toml";
      herdrConfigSha256 = "d2e1b784f6112f14e737f88baf93e77db1e849dc05c8c0790f0128bc15ee1aa2";
    };
    kvantumDanglingLink = {
      literalTarget = "/nix/store/zg2dvqifak33jna83zv40qzy7v9sixib-home-manager-files/.config/Kvantum/Base16Kvantum";
    };
  };
};

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
    criomosHome.herdr = lib.optionalAttrs
      (horizon.node.name == "zeus" && builtins.hasAttr name zeusRecordedHomeAdoption)
      zeusRecordedHomeAdoption.${name};
    # This target owns the authored skill roots and Primary workspace.
    criomosHome.curriculum.enable = horizon.node.name == "ouranos" && name == "li";
    # No new server or authentication-copy activation on the Zeus cutover.
    criomosHome.codexNextCandidate.enable = horizon.node.name != "zeus";
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
