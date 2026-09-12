{
  horizon,
  config,
  lib,
  ...
}:
let
  inherit (builtins)
    mapAttrs
    ;
  inherit (lib)
    optional
    optionalAttrs
    unique
    ;

  inherit (horizon) node;
  users = builtins.listToAttrs (
    map (user: {
      inherit (user) name;
      value = user;
    }) horizon.users
  );
  inherit (node) adminSshPublicKeys behavesAs;
  needsUinputGroup = behavesAs.edge;

  mkUser =
    _attrName: user:
    let
      inherit (user) trust sshPublicKeys;
      authorizedSshPubKeys = unique sshPublicKeys;
      hasMediumTrust = builtins.elem trust [
        "Medium"
        "Large"
        "Max"
      ];
    in
    {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      # `unique` keeps ordinary projected user-key policy canonical. Agent
      # Intercom adds no identity or authorization material.
      openssh.authorizedKeys.keys = authorizedSshPubKeys;

      # horizon-rs gives us the trust-derived list (audio + size.medium:video
      # + size.max:[adbusers,…]); add nixos-module-context groups here.
      extraGroups =
        user.extraGroups
        ++ (optional needsUinputGroup "uinput")
        ++ (optional (config.programs.sway.enable == true) "sway")
        ++ (optional (hasMediumTrust && config.networking.networkmanager.enable == true) "networkmanager");

      linger = user.enableLinger;
    };

  mkUserUsers = mapAttrs mkUser users;

  rootUserAkses = {
    root = {
      openssh.authorizedKeys.keys = adminSshPublicKeys;
    };
  };

in
{
  users = {
    # Edge owns graphical input capability. Headless nodes add no uinput group.
    groups = optionalAttrs needsUinputGroup { uinput = { }; };
    users = mkUserUsers // rootUserAkses;
  };
}
