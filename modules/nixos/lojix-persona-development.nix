{
  config,
  horizon,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  nodeServices = import ./node-services.nix { inherit lib; };
  personaDevelopmentHost = nodeServices.has (horizon.node.services or [ ]) "PersonaDevelopment";
in
lib.mkIf personaDevelopmentHost {
  # PersonaDevelopment is the declarative Lojix owner.  The reusable service
  # module accepts no ambient account, socket, state, or timeout defaults.
  services.lojix = {
    enable = true;
    package = inputs.lojix.packages.${pkgs.stdenv.hostPlatform.system}.default;
    user = "li";
    group = "users";
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
}
