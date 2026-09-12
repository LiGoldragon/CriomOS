{
  config,
  horizon,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (builtins)
    attrNames
    head
    length
    ;
  nodeServices = import ./node-services.nix { inherit lib; };
  personaDevelopmentHost = nodeServices.has (horizon.node.services or [ ]) "PersonaDevelopment";
  localUserNames = attrNames (lib.filterAttrs (_name: user: user.hasPubKey) horizon.users);
  hasExactlyOneLocalUser = length localUserNames == 1;
  localUser = if hasExactlyOneLocalUser then head localUserNames else null;
in
lib.mkIf personaDevelopmentHost (
  lib.mkMerge [
    {
      # PersonaDevelopment owns Lojix through the same node-local identity
      # predicate as userHomes.nix. There must be one, and only one, projected
      # local user; otherwise no authority-bearing daemon is configured.
      assertions = [
        {
          assertion = localUserNames != [ ];
          message = "PersonaDevelopment Lojix identity requires exactly one projected local horizon.users user (hasPubKey); found none";
        }
        {
          assertion = length localUserNames <= 1;
          message = "PersonaDevelopment Lojix identity requires exactly one projected local horizon.users user (hasPubKey); found multiple: ${lib.concatStringsSep ", " localUserNames}";
        }
      ];
    }
    (lib.mkIf hasExactlyOneLocalUser {
      # `users.nix` owns the projected account. Read its evaluated account name
      # and primary group instead of duplicating either identity decision here.
      # The Nexus self-configures from its own Sema store; socket paths, socket
      # modes and the store file are the Nexus's own built-in choices, restated
      # read-only by the module. Only identity and the SSH-agent endpoint are
      # decided here.
      services.lojix = {
        enable = true;
        package = inputs.lojix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        user = config.users.users.${localUser}.name;
        group = config.users.users.${localUser}.group;
        nexusHost = config.networking.hostName;
        sshAuthSocket.mode = "service-user-gpg-agent";
      };
    })
  ]
)
