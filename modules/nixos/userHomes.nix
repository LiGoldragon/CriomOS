{
  config,
  horizon,
  inputs,
  constants,
  lib,
  pkgs,
  ...
}:
let
  inherit (builtins) mapAttrs;

  # Horizon projections have existed in both list and keyed-attribute forms.
  # Preserve a keyed projection as-is; the Home helper converts only the
  # older list form.
  usersByName =
    if builtins.isAttrs horizon.users
    then horizon.users
    else inputs.criomos-home.horizonUsersByName horizon.users;

  mkUserConfig = name: user: {
    _module.args = {
      inherit user;
    };
    home.stateVersion = "26.05";
    # Explicit secondary activation consumer; no node-name feature inference.
    criomosHome.coreHeartbeat = {
      enable = true;
      settings = builtins.fromJSON (builtins.readFile ../../deployments/348e7b-heartbeat.json);
    };
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

  # The OS owns the typed capability and immutable roster artifact. Home
  # receives the artifact source only when the projected OS service is
  # enabled; nodes without Core Checkup keep the ordinary Home surface and
  # do not get a fabricated `/etc` roster.
  coreCheckupHomeModules = lib.optionals config.services.coreCheckup.enable [
    inputs.criomos-home.homeModules."core-checkup-only"
    {
      criomosHome.coreCheckup.rosterFile = config.environment.etc."core-checkup/roster.json".source;
    }
  ];

  # The pinned Home aggregate already imports the wrapper module and exposes
  # its option. Enable that existing module here without importing the
  # exported wrapper a second time: its wrapper also imports Stylix, and a
  # second Stylix import makes Home Manager reject the read-only base16 option.
  codexLayerResumeHomeModules = [
    { criomosHome.codexLayerResume.enable = true; }
  ];

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
    sharedModules =
      [ inputs.criomos-home.homeModules.default ]
      ++ codexLayerResumeHomeModules
      ++ coreCheckupHomeModules;
    useGlobalPkgs = true;
    users = mapAttrs mkUserConfig homeUsers;
  };
}
