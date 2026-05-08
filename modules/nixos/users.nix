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
    optionalAttrs trust.atLeastMin {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      openssh.authorizedKeys.keys = sshPubKeys;

      # horizon-rs gives us the trust-derived list (audio + atLeastMed:video
      # + atLeastMax:[adbusers,…]); add nixos-module-context groups here.
      extraGroups =
        user.extraGroups
        ++ (optional behavesAs.edge "uinput")
        # `chroma` gates access to the visual-state daemon's UDS
        # in /run/chroma/. Auto-granted to graphical users; server-
        # only users (no edge) are excluded by directory permission
        # alone. See modules/nixos/chroma.nix.
        ++ (optional behavesAs.edge "chroma")
        ++ (optional (config.programs.sway.enable == true) "sway")
        ++ (optional (
          trust.atLeastMed && config.networking.networkmanager.enable == true
        ) "networkmanager");

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
