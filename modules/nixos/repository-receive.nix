{
  config,
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (builtins) head length;
  inherit (lib) mkIf;

  nodeServices = import ./node-services.nix { inherit lib; };
  repositoryReceiveEnabled = nodeServices.personaDevelopmentHas (horizon.node.services or [ ]
  ) "GitoliteServer";

  adminSshPubKeys = horizon.node.adminSshPubKeys or [ ];
  gitoliteAdminPubkey =
    if length adminSshPubKeys == 0 then
      throw "repository-receive: horizon.node.adminSshPubKeys must contain at least one key"
    else
      head adminSshPubKeys;

  spoolDirectory = "/var/lib/repository-ledger/spool";
  daemonSocket = "/run/repository-ledger/repository-ledger.sock";
  ownerSocket = "/run/repository-ledger/repository-ledger-owner.sock";
  storePath = "/var/lib/repository-ledger/repository-ledger.redb";
  daemonUser = "repository-ledger";
  daemonGroup = "repository-ledger";
  clientGroup = "nixdev";
  receiveGroup = "repository-ledger-receive";
  repositoryLedgerPackage =
    inputs.repository-ledger.packages.${pkgs.stdenv.hostPlatform.system}.default;
  daemonConfiguration = pkgs.writeText "repository-ledger-daemon.nota" ''
    (RepositoryLedgerDaemonConfiguration "${daemonSocket}" 432 "${ownerSocket}" 384 "${storePath}" "${spoolDirectory}")
  '';

  repositoryLedgerPostReceiveHook = "${pkgs.writeTextDir "post-receive" ''
    #!${pkgs.runtimeShell}
    set -eu
    umask 007

    spool_directory=${lib.escapeShellArg spoolDirectory}
    daemon_socket=${lib.escapeShellArg daemonSocket}
    repository_ledger_cli=${lib.escapeShellArg "${repositoryLedgerPackage}/bin/repository-ledger"}

    escape_nota_string() {
      ${lib.getExe pkgs.gnused} 's/\\/\\\\/g; s/"/\\"/g'
    }

    repository_name=''${GL_REPO:-unknown}
    gitolite_user=''${GL_USER:-unknown}
    timestamp="$(${lib.getExe' pkgs.coreutils "date"} -u +%Y%m%dT%H%M%SZ)"
    safe_repository_name="$(
      printf '%s' "$repository_name" \
        | ${lib.getExe pkgs.gnused} 's/[^A-Za-z0-9._-]/_/g'
    )"

    ${lib.getExe' pkgs.coreutils "mkdir"} -p "$spool_directory"
    direct_request_path="$spool_directory/.$timestamp-$safe_repository_name-$$.direct.nota"
    temporary_path="$spool_directory/.$timestamp-$safe_repository_name-$$.spool.tmp"
    final_path="$spool_directory/$timestamp-$safe_repository_name-$$.nota"

    {
      printf '(RepositoryReceiveHookNotification "%s" "%s" "%s" ' \
        "$(printf '%s' "$repository_name" | escape_nota_string)" \
        "$(printf '%s' "$gitolite_user" | escape_nota_string)" \
        "$timestamp"
      if [ -S "$daemon_socket" ]; then
        printf 'true '
      else
        printf 'false '
      fi
      printf '['
    } >"$direct_request_path"

    {
      printf '%s\n' '(RepositoryReceiveHookNotification'
      printf '  (RepositoryName "%s")\n' "$(printf '%s' "$repository_name" | escape_nota_string)"
      printf '  (GitoliteUser "%s")\n' "$(printf '%s' "$gitolite_user" | escape_nota_string)"
      printf '  (ReceivedAt "%s")\n' "$timestamp"
      if [ -S "$daemon_socket" ]; then
        printf '%s\n' '  (DaemonSocketPresent true)'
      else
        printf '%s\n' '  (DaemonSocketPresent false)'
      fi
      printf '%s\n' '  (RefUpdates'
    } >"$temporary_path"

    first_update=true
    while read -r old_object_id new_object_id ref_name; do
      [ -n "$old_object_id$new_object_id$ref_name" ] || continue
      if [ "$first_update" = true ]; then
        first_update=false
      else
        printf ' ' >>"$direct_request_path"
      fi
      printf '(RefUpdate "%s" "%s" "%s")' \
        "$(printf '%s' "$old_object_id" | escape_nota_string)" \
        "$(printf '%s' "$new_object_id" | escape_nota_string)" \
        "$(printf '%s' "$ref_name" | escape_nota_string)" \
        >>"$direct_request_path"
      printf '    (RefUpdate "%s" "%s" "%s")\n' \
        "$(printf '%s' "$old_object_id" | escape_nota_string)" \
        "$(printf '%s' "$new_object_id" | escape_nota_string)" \
        "$(printf '%s' "$ref_name" | escape_nota_string)" \
        >>"$temporary_path"
    done

    printf '%s\n' '])' >>"$direct_request_path"
    {
      printf '%s\n' '  )'
      printf '%s\n' ')'
    } >>"$temporary_path"

    if REPOSITORY_LEDGER_SOCKET_PATH="$daemon_socket" "$repository_ledger_cli" "$direct_request_path" >/dev/null 2>&1; then
      ${lib.getExe' pkgs.coreutils "rm"} -f "$direct_request_path" "$temporary_path"
      exit 0
    fi

    ${lib.getExe' pkgs.coreutils "chmod"} 0640 "$temporary_path"
    ${lib.getExe' pkgs.coreutils "mv"} "$temporary_path" "$final_path"
    ${lib.getExe' pkgs.coreutils "rm"} -f "$direct_request_path"
    exit 0
  ''}/post-receive";
in
{
  config = mkIf repositoryReceiveEnabled {
    services.gitolite = {
      enable = true;
      adminPubkey = gitoliteAdminPubkey;
      dataDir = "/var/lib/gitolite";
      commonHooks = [ repositoryLedgerPostReceiveHook ];
    };

    environment.systemPackages = [ repositoryLedgerPackage ];

    users.groups.${daemonGroup} = { };
    users.groups.${clientGroup}.members = [
      config.services.gitolite.user
      daemonUser
    ];
    users.groups.${receiveGroup}.members = [
      config.services.gitolite.user
      daemonUser
    ];

    users.users.${daemonUser} = {
      isSystemUser = true;
      group = daemonGroup;
      description = "Repository ledger daemon user";
      home = "/var/lib/repository-ledger";
    };

    systemd.services.repository-ledger = {
      description = "Repository ledger daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "gitolite-init.service" ];
      serviceConfig = {
        Type = "simple";
        User = daemonUser;
        Group = clientGroup;
        SupplementaryGroups = [
          daemonGroup
          receiveGroup
        ];
        WorkingDirectory = "/var/lib/repository-ledger";
        ExecStart = "${repositoryLedgerPackage}/bin/repository-ledger-daemon ${daemonConfiguration}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0007";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          "/var/lib/repository-ledger"
          "/run/repository-ledger"
        ];
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/repository-ledger 2770 ${daemonUser} ${receiveGroup} -"
      "d ${spoolDirectory} 2770 ${config.services.gitolite.user} ${receiveGroup} -"
      "d /run/repository-ledger 0755 ${daemonUser} ${clientGroup} -"
    ];
  };
}
