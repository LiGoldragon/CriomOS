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
      homeFiles = "/nix/store/pyygmax9va0111y51a9azrbbqy9iai88-home-manager-files";
      herdrConfig = "/nix/store/awxpsb8p1jbakkmqq28z8nd6hr872vx2-herdr-config.toml";
      herdrConfigSha256 = "edeb91e14cf1a01de87c2d8ee7230a2bb8058a2aba6f367ff6363cdea53b7848";
    };
    kvantumDanglingLink = {
      literalTarget = "/nix/store/hm19bndn5aicvhmcr6a9m4x10i3871hl-home-manager-files/.config/Kvantum/Base16Kvantum";
    };
  };
  li = {
    predecessorGeneration = {
      homeFiles = "/nix/store/ql0n67j2w25sqwixcp0d7911qxzq56qs-home-manager-files";
      herdrConfig = "/nix/store/c7fz4drhaf41bkhcqmzd9m5hg8v6rb6v-herdr-config.toml";
      herdrConfigSha256 = "b18985fb3168fb582787c5099689e82278a403ca40456d5ef9d5f36b5cc610b5";
    };
    kvantumDanglingLink = {
      literalTarget = "/nix/store/zg2dvqifak33jna83zv40qzy7v9sixib-home-manager-files/.config/Kvantum/Base16Kvantum";
    };
  };
};

  mkUserConfig = name: user: {
    _module.args = {
      inherit user;
    };
    home.stateVersion = "26.05";
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
