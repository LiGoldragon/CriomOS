{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";
  optionEvaluationPlaceholder = "repository-receive-option-evaluation-placeholder-not-key-material";

  baseNode = {
    services = [ ];
  };

  receiveNode = {
    # This check only proves module gating and hook installation. The
    # Gitolite option is an unvalidated string at Nix evaluation time,
    # so use an obvious non-key placeholder instead of key-shaped test
    # data. Real public keys come from projected Horizon user data.
    adminSshPubKeys = [ optionEvaluationPlaceholder ];
    services = [
      {
        PersonaDevelopment = {
          capabilities = [
            { GitoliteServer = { }; }
          ];
        };
      }
    ];
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
  receiveGroupMembers =
    lib.concatStringsSep " "
      receiveConfiguration.config.users.groups."repository-ledger-receive".members;
  receiveDaemonUser = receiveConfiguration.config.users.users."repository-ledger";
  receiveDaemonService = receiveConfiguration.config.systemd.services.repository-ledger;
  receiveDaemonServiceConfig = receiveDaemonService.serviceConfig;
  receiveSystemPackageNames = lib.concatStringsSep " " (
    map (
      package: package.pname or package.name or "unnamed"
    ) receiveConfiguration.config.environment.systemPackages
  );

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
  printf '%s' ${lib.escapeShellArg hookText} | grep -F 'umask 007'
  printf '%s' ${lib.escapeShellArg hookText} | grep -F '0640 "$temporary_path"'

  test ${lib.escapeShellArg receiveDaemonUser.group} = repository-ledger
  printf '%s' ${lib.escapeShellArg receiveGroupMembers} | grep -F gitolite
  printf '%s' ${lib.escapeShellArg receiveGroupMembers} | grep -F repository-ledger
  test ${lib.escapeShellArg receiveDaemonService.description} = 'Repository ledger daemon'
  test ${lib.escapeShellArg receiveDaemonServiceConfig.User} = repository-ledger
  test ${lib.escapeShellArg receiveDaemonServiceConfig.Group} = nixdev
  printf '%s' ${lib.escapeShellArg (builtins.toJSON receiveDaemonServiceConfig.SupplementaryGroups)} | grep -F repository-ledger-receive
  printf '%s' ${lib.escapeShellArg receiveDaemonServiceConfig.ExecStart} | grep -F '/bin/repository-ledger-daemon'
  printf '%s' ${lib.escapeShellArg receiveDaemonServiceConfig.ExecStart} | grep -F 'repository-ledger-daemon.nota'
  printf '%s' ${lib.escapeShellArg receiveSystemPackageNames} | grep -F repository-ledger

  printf '%s' ${lib.escapeShellArg receiveTmpfiles} | grep -F 'd /var/lib/repository-ledger 2770 repository-ledger repository-ledger-receive -'
  printf '%s' ${lib.escapeShellArg receiveTmpfiles} | grep -F '/var/lib/repository-ledger/spool'
  printf '%s' ${lib.escapeShellArg receiveTmpfiles} | grep -F 'd /run/repository-ledger 0755 repository-ledger nixdev -'

  touch "$out"
''
