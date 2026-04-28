{
  horizon,
  inputs,
  constants,
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
    users = mapAttrs mkUserConfig horizon.users;
  };
}
