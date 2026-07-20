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

  inherit (horizon) node users;
  inherit (node) adminSshPubKeys behavesAs;

  mkUser =
    _attrName: user:
    let
      inherit (user) trust sshPubKeys;
      agentIntercomGatewaySshPubKey = user.agentIntercomGatewaySshPubKey or null;
      authorizedSshPubKeys = unique (
        sshPubKeys ++ optional (agentIntercomGatewaySshPubKey != null) agentIntercomGatewaySshPubKey
      );
    in
    optionalAttrs trust.min {
      name = user.name;

      useDefaultShell = true;
      isNormalUser = true;

      # When Agent Intercom has a projected gateway, this explicitly retains
      # that gateway's public identity in the peer user's authorization set.
      # `unique` keeps the ordinary per-user key policy canonical.
      openssh.authorizedKeys.keys = authorizedSshPubKeys;

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
