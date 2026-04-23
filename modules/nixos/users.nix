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
  inherit (node.methods) adminSshPubKeys behavesAs;

  mkUser =
    attrName: user:
    let
      inherit (user) trust;
      inherit (user.methods) sshPubKeys;

    in
    optionalAttrs (trust > 0) {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      openssh.authorizedKeys.keys = sshPubKeys;

      extraGroups =
        [ "audio" ]
        ++ (optional (config.programs.sway.enable == true) "sway")
        ++ (optionals (trust >= 2) (
          [ "video" ] ++ (optional (config.networking.networkmanager.enable == true) "networkmanager")
        ))
        ++ (optionals (trust >= 3) [
          "adbusers"
          "nixdev"
          "systemd-journal"
          "dialout"
          "plugdev"
          "power"
          "storage"
          "libvirtd"
        ]);

      linger = trust >= 3 && behavesAs.center;
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
