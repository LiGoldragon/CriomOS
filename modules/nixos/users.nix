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
    ;

  inherit (horizon) node users;
  inherit (node) adminSshPubKeys behavesAs;

  mkUser =
    _attrName: user:
    let
      inherit (user) trust sshPubKeys;
    in
    optionalAttrs trust.min {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      openssh.authorizedKeys.keys = sshPubKeys;

      # horizon-rs gives us the trust-derived list (audio + size.medium:video
      # + size.max:[adbusers,…]); add nixos-module-context groups here.
      extraGroups =
        user.extraGroups
        ++ (optional behavesAs.edge "uinput")
        ++ (optional (config.programs.sway.enable == true) "sway")
        ++ (optional (trust.medium && config.networking.networkmanager.enable == true) "networkmanager");

      linger = user.enableLinger;
    };

  mkUserUsers = mapAttrs mkUser users;

  rootUserAkses = {
    root = {
      openssh.authorizedKeys.keys = adminSshPubKeys;
    };
  };

in
{
  users = {
    groups.uinput = { };
    users = mkUserUsers // rootUserAkses;
  };
}
