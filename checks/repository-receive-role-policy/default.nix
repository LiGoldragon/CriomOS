{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseNode = {
    adminSshPubKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureAdminKey" ];
    services = { };
  };

  receiveNode = {
    adminSshPubKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureAdminKey" ];
    services.personaDevelopment.Workstation.repositoryReceive.localOnly = true;
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/repository-receive.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  baseConfiguration = configurationFor baseNode;
  receiveConfiguration = configurationFor receiveNode;

  hookPath = builtins.head receiveConfiguration.config.services.gitolite.commonHooks;
  hookText = builtins.readFile hookPath;
  hookBaseName = baseNameOf (toString hookPath);

  receiveTmpfiles = lib.concatStringsSep "\n" receiveConfiguration.config.systemd.tmpfiles.rules;
in
pkgs.runCommand "repository-receive-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool baseConfiguration.config.services.gitolite.enable)} = false
  test ${lib.escapeShellArg (bool receiveConfiguration.config.services.gitolite.enable)} = true
  test ${lib.escapeShellArg receiveConfiguration.config.services.gitolite.dataDir} = /var/lib/gitolite
  test ${lib.escapeShellArg hookBaseName} = post-receive

  printf '%s' ${lib.escapeShellArg hookText} | grep -F '/var/lib/repository-ledger/spool'
  printf '%s' ${lib.escapeShellArg hookText} | grep -F 'RepositoryReceiveHookNotification'
  printf '%s' ${lib.escapeShellArg receiveTmpfiles} | grep -F '/var/lib/repository-ledger/spool'

  touch "$out"
''
