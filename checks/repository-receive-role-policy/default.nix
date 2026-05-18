{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";
  optionEvaluationPlaceholder = "repository-receive-option-evaluation-placeholder-not-key-material";

  baseNode = {
    services = { };
  };

  receiveNode = {
    # This check only proves module gating and hook installation. The
    # Gitolite option is an unvalidated string at Nix evaluation time,
    # so use an obvious non-key placeholder instead of key-shaped test
    # data. Real public keys come from projected Horizon user data.
    adminSshPubKeys = [ optionEvaluationPlaceholder ];
    services.personaDevelopment = true;
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

  receiveAdminPubkey = receiveConfiguration.config.services.gitolite.adminPubkey;
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
  test ${lib.escapeShellArg receiveAdminPubkey} = ${lib.escapeShellArg optionEvaluationPlaceholder}
  ! printf '%s' ${lib.escapeShellArg receiveAdminPubkey} | grep -E '^ssh-[A-Za-z0-9-]+ '
  test ${lib.escapeShellArg hookBaseName} = post-receive

  printf '%s' ${lib.escapeShellArg hookText} | grep -F '/var/lib/repository-ledger/spool'
  printf '%s' ${lib.escapeShellArg hookText} | grep -F 'RepositoryReceiveHookNotification'
  printf '%s' ${lib.escapeShellArg receiveTmpfiles} | grep -F '/var/lib/repository-ledger/spool'

  touch "$out"
''
