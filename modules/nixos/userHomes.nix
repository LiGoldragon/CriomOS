{
  horizon,
  inputs,
  ...
}:
let
  inherit (builtins) mapAttrs;

  mkUserConfig = _name: user: {
    _module.args = {
      inherit user;
    };
  };

in
{
  home-manager = {
    backupFileExtension = "backup";
    extraSpecialArgs = {
      inherit horizon inputs;
    };
    sharedModules = [ inputs.criomos-home.homeModules.default ];
    useGlobalPkgs = true;
    users = mapAttrs mkUserConfig horizon.users;
  };
}
