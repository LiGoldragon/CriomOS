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
    optionals
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
    optionalAttrs trust.is.min {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      openssh.authorizedKeys.keys = sshPubKeys;

      extraGroups =
        [ "audio" ]
        ++ (optional (config.programs.sway.enable == true) "sway")
        ++ (optionals trust.is.med (
          [ "video" ] ++ (optional (config.networking.networkmanager.enable == true) "networkmanager")
        ))
        ++ (optionals trust.is.max [
          "adbusers"
          "nixdev"
          "systemd-journal"
          "dialout"
          "plugdev"
          "power"
          "storage"
          "libvirtd"
        ]);

      linger = trust.is.max && behavesAs.center;
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
    users = mkUserUsers // rootUserAkses;
  };
}
