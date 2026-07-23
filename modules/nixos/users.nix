{
  horizon,
  config,
  lib,
  ...
}:
let
  nodeServices = import ./node-services.nix { inherit lib; };
  agentIntercomLocal = nodeServices.has (horizon.node.services or [ ]) "AgentIntercomLocal";
  agentIntercomGraphical =
    agentIntercomLocal && nodeServices.has (horizon.node.services or [ ]) "AgentIntercomGraphical";

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
  needsUinputGroup = behavesAs.edge || agentIntercomGraphical;

  mkUser =
    _attrName: user:
    let
      inherit (user) trust sshPubKeys;
      authorizedSshPubKeys = unique sshPubKeys;
    in
    optionalAttrs trust.min {
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
    # Retain the existing edge policy, and add the group for the valid
    # local-plus-graphical capability only. Headless capability sets add none.
    groups = optionalAttrs needsUinputGroup { uinput = { }; };
    users = mkUserUsers // rootUserAkses;
  };
}
