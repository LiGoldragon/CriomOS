{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  configFor = extra: (lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      ../../modules/nixos/git-publication.nix
      { system.stateVersion = "26.05"; }
      extra
    ];
  }).config;
  disabled = configFor {};
  endpoint = {
    enable = true;
    peer = "localhost";
    knownHosts = pkgs.writeText "known-publication-peer" "";
    identityFile = "/run/credentials/publication";
    authorizedKeys = [ "ssh-ed25519 AAAA" ];
  };
  enabled = configFor {
    services.openssh.enable = true;
    users.groups.git = {};
    users.users.git = { isSystemUser = true; group = "git"; };
    criomos.gitPublication = {
      repositories = [ "sample/psyche" "sample/mind" "sample/field" ];
      sender = endpoint;
      receiver = endpoint;
    };
  };
  value = lib.escapeShellArg;
  keys = user: builtins.head enabled.users.users.${user}.openssh.authorizedKeys.keys;
in
assert disabled.criomos.gitPublication.enqueueCommand == null;
assert !(disabled.systemd.paths ? git-publication-deliver);
assert enabled.criomos.gitPublication.enqueueCommand != null;
pkgs.runCommand "git-publication-delivery" { nativeBuildInputs = [ pkgs.git pkgs.python3 ]; } ''
  test ${value enabled.systemd.paths.git-publication-deliver.pathConfig.PathExists} = /var/lib/git-publication-wake/ready
  printf '%s\n' ${value (keys "git-publication-wake")} | grep -E '^restrict,command="[^"]+git-publication-wake" ssh-ed25519 '
  printf '%s\n' ${value (keys "git-publication-receiver")} | grep -E '^restrict,command="[^"]+git-publication-receive" ssh-ed25519 '
  python3 ${./contract.py} ${../../modules/nixos/git-publication/delivery.py} | tee "$out"
''
