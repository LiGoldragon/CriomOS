{
  config,
  lib,
  pkgs,
  horizon,
  ...
}:
let
  inherit (lib)
    concatMapStringsSep
    filter
    filterAttrs
    head
    attrValues
    mkIf
    mkMerge
    ;
  inherit (horizon) node users;

  # The cluster's Git server is the node whose cluster data gives it the
  # GitServer capability. Every node reaches it at its gitServerDomain as
  # the git user; the server takes its users and their SSH keys from the
  # cluster's users, and the users of the highest trust administer.
  allNodes = {
    "${node.name}" = node;
  }
  // (horizon.exNodes or { });
  gitServers = attrValues (filterAttrs (_: entry: entry.isGitServer or false) allNodes);
  gitServer = if gitServers == [ ] then null else head gitServers;
  isGitServer = node.isGitServer or false;
  serverUser = "git";

  trustRank = {
    Zero = 0;
    Min = 1;
    Medium = 2;
    Large = 3;
    Max = 4;
  };
  rankOf = user: trustRank.${user.trust} or 0;
  highestTrust = lib.foldl' (highest: user: lib.max highest (rankOf user)) 0 users;
  keyedUsers = filter (user: user.publicKeys != [ ]) users;
  administrators = filter (user: rankOf user == highestTrust) keyedUsers;

  # gitolite reads keydir/<any subdirectory>/<user>.pub as one more key of
  # that user, so each node's key of a user is its own file.
  keydir = pkgs.linkFarm "git-server-keydir" (
    lib.concatMap (
      user:
      map (publicKey: {
        name = "${publicKey.node}/${user.name}.pub";
        path = pkgs.writeText "${user.name}-${publicKey.node}.pub" "ssh-ed25519 ${publicKey.ssh} ${user.name}@${publicKey.node}\n";
      }) user.publicKeys
    ) keyedUsers
  );

  # Each user creates and writes the repositories of his own namespace,
  # named by the user rather than by whoever created the repository;
  # administrators create and write any repository; everyone reads. Nobody
  # writes gitolite-admin, so the declaration stays the only configuration.
  userNamespace = user: ''
    repo ${user.name}/..*
        C   = ${user.name}
        RW+ = ${user.name}
  '';
  gitoliteConfiguration = pkgs.writeText "gitolite.conf" ''
    @administrators = ${concatMapStringsSep " " (user: user.name) administrators}

    repo gitolite-admin
        R   = @administrators
        -   = @all

    ${concatMapStringsSep "\n" userNamespace keyedUsers}

    repo ..*
        C   = @administrators
        RW+ = @administrators
        R   = @all
  '';

  # The configuration is compiled from the declaration, never from pushes
  # to gitolite-admin: the unit runs again whenever its inputs change.
  configureGitServer = pkgs.writeShellScript "git-server-configure" ''
    set -eu
    base="${config.services.gitolite.dataDir}/.gitolite"
    ${pkgs.coreutils}/bin/install -d -m 0700 "$base/conf"
    ${pkgs.coreutils}/bin/install -m 0600 ${gitoliteConfiguration} "$base/conf/gitolite.conf"
    ${pkgs.coreutils}/bin/rm -rf "$base/keydir"
    ${pkgs.coreutils}/bin/cp -rL ${keydir} "$base/keydir"
    ${pkgs.coreutils}/bin/chmod -R u+w "$base/keydir"
    ${pkgs.gitolite}/bin/gitolite compile
    ${pkgs.gitolite}/bin/gitolite trigger POST_COMPILE
  '';
in
mkMerge [
  (mkIf isGitServer {
    assertions = [
      {
        assertion = administrators != [ ];
        message = "git server: no cluster user with an SSH key holds the highest trust";
      }
    ];

    services.gitolite = {
      enable = true;
      user = serverUser;
      group = serverUser;
      dataDir = "/var/lib/git-server";
      adminPubkey = "ssh-ed25519 ${(head (head administrators).publicKeys).ssh}";
    };

    systemd.services.git-server-configure = {
      description = "Compile the Git server's users and repositories from the cluster data";
      wantedBy = [ "multi-user.target" ];
      requires = [ "gitolite-init.service" ];
      after = [ "gitolite-init.service" ];
      restartTriggers = [
        gitoliteConfiguration
        keydir
      ];
      environment.HOME = config.services.gitolite.dataDir;
      path = [
        pkgs.git
        pkgs.gitolite
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = serverUser;
        Group = serverUser;
        ExecStart = configureGitServer;
      };
    };
  })

  (mkIf (gitServer != null) {
    # Every node reaches the server by its cluster name as the git user,
    # so a remote or a flake input names it bare: git+ssh://<domain>/<repo>.
    programs.ssh.extraConfig = ''
      Host ${gitServer.gitServerDomain}
        User ${serverUser}
    '';
    programs.ssh.knownHosts.git-server = {
      hostNames = [ gitServer.gitServerDomain ];
      publicKey = gitServer.sshPublicKeyLine;
    };
  })
]
