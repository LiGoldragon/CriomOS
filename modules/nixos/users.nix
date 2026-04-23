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
  inherit (node.methods) adminSshPreCriomes behavesAs;

  mkUser =
    attrName: user:
    let
      inherit (user) trust;
      inherit (user.methods) sshCriomes;

    in
    optionalAttrs (trust > 0) {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      openssh.authorizedKeys.keys = sshCriomes;

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
      openssh.authorizedKeys.keys = adminSshPreCriomes;
    };
  };

in
{
  users = {
    users = mkUserUsers // rootUserAkses;
  };
}
