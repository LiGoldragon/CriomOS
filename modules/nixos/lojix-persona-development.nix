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
    filter
    head
    length
    ;
  nodeServices = import ./node-services.nix { inherit lib; };
  personaDevelopmentHost = nodeServices.has (horizon.node.capabilities or [ ]) "personaDevelopment";
  localUserNames = map (user: user.name) (filter (user: user.hasPublicKey) horizon.users);
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
          message = "PersonaDevelopment Lojix identity requires exactly one projected local Horizon user (hasPublicKey); found none";
        }
        {
          assertion = length localUserNames <= 1;
          message = "PersonaDevelopment Lojix identity requires exactly one projected local Horizon user (hasPublicKey); found multiple: ${lib.concatStringsSep ", " localUserNames}";
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
        sshAuthSocket.mode = "service-user-gpg-agent";
      };
    })
  ]
)
