{
  horizon,
  config,
  lib,
  ...
}:
let
  inherit (builtins) listToAttrs;
  inherit (lib)
    optional
    optionalAttrs
    unique
    ;

  inherit (horizon) node users;
  inherit (node) adminSshPublicKeys behavesAs;
  needsUinputGroup = behavesAs.edge;

  mkUser =
    user:
    let
      authorizedSshPubKeys = unique user.sshPublicKeys;
    in
    {
      name = user.name;
      value = optionalAttrs (user.trust != "Zero") {
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
          ++ (optional (
            user.trust != "Zero" && config.networking.networkmanager.enable == true
          ) "networkmanager");

        linger = user.enableLinger;
      };
    };

  mkUserUsers = listToAttrs (map mkUser users);

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
