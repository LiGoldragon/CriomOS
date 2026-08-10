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
      services.lojix = {
        enable = true;
        package = inputs.lojix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        user = config.users.users.${localUser}.name;
        group = config.users.users.${localUser}.group;
        ordinarySocketPath = "/run/lojix/ordinary.sock";
        ordinarySocketMode = 432;
        ownerSocketPath = "/run/lojix/owner.sock";
        ownerSocketMode = 384;
        stateDirectoryPath = "/var/lib/lojix";
        storePath = "/var/lib/lojix/lojix.sema";
        startupArchivePath = "/run/lojix/startup.rkyv";
        daemonHost = config.networking.hostName;
        effectTimeoutSeconds = 2700;
      };
    })
  ]
)
