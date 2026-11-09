{
  config,
  lib,
  pkgs,
  horizon,
  ...
}:
let
  inherit (lib)
    attrValues
    concatMapStringsSep
    concatStringsSep
    filter
    filterAttrs
    head
    mkIf
    mkMerge
    mkOption
    sort
    types
    ;
  inherit (horizon) node users;
  cfg = config.criomos.gitServer;

  # The cluster's Git servers are the nodes whose cluster data gives them the
  # GitServer capability. They are ordered by preference: a node the owner
  # holds (no CloudNode) before a cloud node, then by name. The most
  # preferred server is the writable primary while it serves; the others are
  # standbys that receive its pushes and take the writes when it is gone.
  allNodes = {
    "${node.name}" = node;
  }
  // (horizon.exNodes or { });
  isCloud = entry: entry.behavesAs.cloudNode or false;
  preferredBefore =
    left: right: if isCloud left != isCloud right then !(isCloud left) else left.name < right.name;
  servers = sort preferredBefore (
    attrValues (filterAttrs (_: entry: entry.isGitServer or false) allNodes)
  );
  preferredServer = if servers == [ ] then null else head servers;
  isGitServer = node.isGitServer or false;
  peers = filter (entry: entry.name != node.name) servers;
  serverUser = "git";
  gitDomain = preferredServer.gitServerDomain;
  serverIdentity = entry: "server-${entry.name}";
  serverIdentities = map serverIdentity servers;
  serverRanks = concatStringsSep " " (map (entry: entry.name) servers);

  dataDir = "/var/lib/git-server";
  repositories = "${dataDir}/repositories";
  stateDir = "${dataDir}/cluster";
  eventsDir = "${stateDir}/events";
  mirrorQueue = "${stateDir}/mirror-queue";
  roleFile = "${stateDir}/role";
  hostKey = "/etc/ssh/ssh_host_ed25519_key";

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
  # that user, so each node's key of a user is its own file. Every Git server
  # is a user too, by its host key, so the servers push to each other.
  keydir = pkgs.linkFarm "git-server-keydir" (
    lib.concatMap (
      user:
      map (publicKey: {
        name = "${publicKey.node}/${user.name}.pub";
        path = pkgs.writeText "${user.name}-${publicKey.node}.pub" "ssh-ed25519 ${publicKey.ssh} ${user.name}@${publicKey.node}\n";
      }) user.publicKeys
    ) keyedUsers
    ++ map (entry: {
      name = "servers/${serverIdentity entry}.pub";
      path = pkgs.writeText "${serverIdentity entry}.pub" "${entry.sshPublicKeyLine}\n";
    }) servers
  );

  # Each user creates and writes the repositories of his own namespace,
  # named by the user rather than by whoever created the repository;
  # administrators create and write any repository; the servers create and
  # write any repository, to carry each other's pushes; everyone reads.
  # Nobody writes gitolite-admin, so the declaration stays the only
  # configuration.
  userNamespace = user: ''
    repo ${user.name}/..*
        C   = ${user.name}
        RW+ = ${user.name}
  '';
  gitoliteConfiguration = pkgs.writeText "gitolite.conf" ''
    @administrators = ${concatMapStringsSep " " (user: user.name) administrators}
    @servers = ${concatStringsSep " " serverIdentities}

    repo gitolite-admin
        R   = @administrators
        -   = @all

    ${concatMapStringsSep "\n" userNamespace keyedUsers}

    repo [a-zA-Z0-9].*
        C   = @administrators @servers
        RW+ = @administrators @servers
        R   = @all
  '';

  # A shell function every hook and command opens with: whether the
  # gitolite user is one of the cluster's Git servers.
  isServerIdentity = ''
    is_server() {
      case " ${concatStringsSep " " serverIdentities} " in
        *" $GL_USER "*) return 0 ;;
        *) return 1 ;;
      esac
    }
  '';

  # A write reaches the primary, which takes it; a server's push reaches a
  # standby, which takes it and knows the primary is alive. A user's write
  # reaching a standby means the primary was unreachable for that user: the
  # write is refused and the event starts the promotion timer.
  preReceive = pkgs.writeShellScript "pre-receive" ''
    ${isServerIdentity}
    if is_server; then
      date > ${eventsDir}/peer-alive
      exit 0
    fi
    if [ "$(cat ${roleFile})" = primary ]; then
      exit 0
    fi
    date > ${eventsDir}/primary-unreachable
    echo "git server ${node.name}: the primary was unreachable, so this standby takes the writes after ${cfg.promotionDelay} unless it returns; push again then." >&2
    exit 1
  '';

  # The primary queues every repository it receives a push to; the mirror
  # service carries it to the other servers.
  postReceive = pkgs.writeShellScript "post-receive" ''
    ${isServerIdentity}
    if [ "$(cat ${roleFile})" = primary ] && ! is_server; then
      printf '%s\n' "$GL_REPO" > "${mirrorQueue}/$(printf '%s' "$GL_REPO" | ${pkgs.coreutils}/bin/tr / %)"
    fi
    exit 0
  '';

  # A server returning announces itself to each other server: that server
  # knows the returning one is alive, steps down from primary if the
  # returning one is preferred to it, and answers its role and its
  # repositories so the returning one fetches what landed while it was gone.
  announceCommand = pkgs.writeShellScript "git-server-announce" ''
    set -eu
    ${isServerIdentity}
    if ! is_server; then
      echo "only a Git server of the cluster announces itself" >&2
      exit 1
    fi
    announcer="''${GL_USER#server-}"
    date > ${eventsDir}/peer-alive
    rank() {
      position=0
      for name in ${serverRanks}; do
        [ "$name" = "$1" ] && { echo "$position"; return; }
        position=$((position + 1))
      done
      echo "$position"
    }
    role="$(cat ${roleFile})"
    if [ "$role" = primary ] && [ "$(rank "$announcer")" -lt "$(rank ${node.name})" ]; then
      echo standby > ${roleFile}
      role=demoted
    fi
    echo "role $role"
    cd ${repositories}
    ${pkgs.findutils}/bin/find . -name '*.git' -type d -prune \
      | ${pkgs.gnused}/bin/sed -e 's|^\./||' -e 's|\.git$||' \
      | ${pkgs.gnugrep}/bin/grep -v '^gitolite-admin$' \
      | while read -r repository; do echo "repository $repository"; done
  '';

  localCode = pkgs.linkFarm "git-server-local-code" [
    {
      name = "hooks/common/pre-receive";
      path = preReceive;
    }
    {
      name = "hooks/common/post-receive";
      path = postReceive;
    }
    {
      name = "commands/git-server-announce";
      path = announceCommand;
    }
  ];

  sshToPeer = "${pkgs.openssh}/bin/ssh -i $CREDENTIALS_DIRECTORY/host-key -p ${toString cfg.port} -o BatchMode=yes -o ConnectTimeout=10";

  # Carries each queued repository to every other server.
  mirror = pkgs.writeShellScript "git-server-mirror" ''
    set -u
    export GIT_SSH_COMMAND="${sshToPeer}"
    for entry in ${mirrorQueue}/*; do
      [ -e "$entry" ] || continue
      repository="$(cat "$entry")"
      rm -f "$entry"
      for peer in ${concatMapStringsSep " " (entry: entry.criomeDomainName) peers}; do
        ${pkgs.git}/bin/git -C "${repositories}/$repository.git" push --quiet --mirror "${serverUser}@$peer:$repository" \
          && echo "mirrored $repository to $peer" \
          || echo "mirror of $repository to $peer failed"
      done
    done
  '';

  # Run before the server listens: announce to each other server, fetch every
  # repository it holds, fast-forward only, and keep a diverged branch under
  # refs/quarantine/<server>/ for a person to settle. The most preferred
  # server is then the primary; any other is a standby.
  returnToCluster = pkgs.writeShellScript "git-server-return" ''
    set -u
    export GIT_SSH_COMMAND="${sshToPeer}"
    git=${pkgs.git}/bin/git
    for pair in ${concatMapStringsSep " " (entry: "${entry.name}=${entry.criomeDomainName}") peers}; do
      peer="''${pair%%=*}"
      domain="''${pair#*=}"
      answer="$(${sshToPeer} ${serverUser}@$domain git-server-announce)" || {
        echo "$peer did not answer; it is down or unreachable"
        continue
      }
      echo "$peer answered: $(printf '%s\n' "$answer" | head -n 1)"
      printf '%s\n' "$answer" | ${pkgs.gnused}/bin/sed -n 's/^repository //p' | while read -r repository; do
        directory="${repositories}/$repository.git"
        if [ ! -d "$directory" ]; then
          $git init --quiet --bare "$directory"
          touch ${stateDir}/hooks-needed
        fi
        quarantine="refs/quarantine/$peer"
        $git -C "$directory" fetch --quiet --no-tags "${serverUser}@$domain:$repository" \
          "+refs/heads/*:$quarantine/heads/*" "+refs/tags/*:$quarantine/tags/*" || {
          echo "fetch of $repository from $peer failed"
          continue
        }
        $git -C "$directory" for-each-ref --format='%(refname) %(objectname)' "$quarantine/" \
          | while read -r fetched object; do
              local="refs/''${fetched#$quarantine/}"
              current="$($git -C "$directory" rev-parse --quiet --verify "$local")"
              if [ -z "$current" ] || $git -C "$directory" merge-base --is-ancestor "$current" "$object"; then
                [ "$current" = "$object" ] || echo "$repository $local takes $object from $peer"
                $git -C "$directory" update-ref "$local" "$object"
                $git -C "$directory" update-ref -d "$fetched"
              elif $git -C "$directory" merge-base --is-ancestor "$object" "$current"; then
                $git -C "$directory" update-ref -d "$fetched"
              else
                echo "DIVERGED: $repository $local differs from $peer; theirs kept at $fetched"
              fi
            done
      done
    done
    if [ -e ${stateDir}/hooks-needed ]; then
      ${pkgs.gitolite}/bin/gitolite setup --hooks-only
      rm -f ${stateDir}/hooks-needed
    fi
    ${
      if preferredServer != null && preferredServer.name == node.name then
        "echo primary > ${roleFile}"
      else
        "echo standby > ${roleFile}"
    }
    echo "role $(cat ${roleFile})"
  '';

  sshdConfiguration = pkgs.writeText "git-server-sshd.conf" ''
    HostKey ${hostKey}
    AuthorizedKeysFile ${dataDir}/.ssh/authorized_keys
    AllowUsers ${serverUser}
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    AllowTcpForwarding no
    X11Forwarding no
  '';

  # A user reaches the cluster's Git by its name: the servers are tried in
  # their order of preference, and the first that accepts carries the
  # connection.
  connect = pkgs.writeShellScript "git-server-connect" ''
    for server in ${concatMapStringsSep " " (entry: entry.criomeDomainName) servers}; do
      if ${pkgs.netcat-openbsd}/bin/nc -z -w 5 "$server" "$1" 2>/dev/null; then
        exec ${pkgs.netcat-openbsd}/bin/nc "$server" "$1"
      fi
    done
    echo "no Git server of the cluster answers" >&2
    exit 1
  '';

  # gitolite forks ssh-keygen for the keys and perl for its triggers.
  gitolitePath = [
    pkgs.git
    pkgs.gitolite
    pkgs.openssh
    pkgs.perl
  ];
  serviceEnvironment = {
    HOME = dataDir;
  };
  asServer = {
    User = serverUser;
    Group = serverUser;
  };
in
{
  options.criomos.gitServer = {
    port = mkOption {
      type = types.port;
      default = 2222;
      description = "The port each Git server listens on for Git over SSH, apart from the host's own SSH.";
    };
    promotionDelay = mkOption {
      type = types.str;
      default = "2min";
      description = "How long a standby waits, from a write that found the primary unreachable, before it takes the writes.";
    };
  };

  config = mkMerge [
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
        inherit dataDir;
        adminPubkey = "ssh-ed25519 ${(head (head administrators).publicKeys).ssh}";
        extraGitoliteRc = ''
          $RC{LOCAL_CODE} = "${localCode}";
          push( @{$RC{ENABLE}}, 'git-server-announce' );
        '';
      };

      # gitolite's own module makes its directories only at its default
      # path, so the server's home is declared here, owned by the git user.
      systemd.tmpfiles.rules = [
        "d ${dataDir} 0750 ${serverUser} ${serverUser} -"
        "d ${dataDir}/.gitolite 0750 ${serverUser} ${serverUser} -"
        "d ${dataDir}/.gitolite/logs 0750 ${serverUser} ${serverUser} -"
        "d ${stateDir} 0755 ${serverUser} ${serverUser} -"
        "d ${eventsDir} 0755 ${serverUser} ${serverUser} -"
        "d ${mirrorQueue} 0755 ${serverUser} ${serverUser} -"
        "f ${roleFile} 0644 ${serverUser} ${serverUser} - ${
          if preferredServer.name == node.name then "primary" else "standby"
        }"
      ];

      # The configuration is compiled from the declaration, never from pushes
      # to gitolite-admin: the unit runs again whenever its inputs change.
      systemd.services.git-server-configure = {
        description = "Compile the Git server's users and repositories from the cluster data";
        wantedBy = [ "multi-user.target" ];
        requires = [ "gitolite-init.service" ];
        after = [ "gitolite-init.service" ];
        restartTriggers = [
          gitoliteConfiguration
          keydir
          localCode
        ];
        environment = serviceEnvironment;
        path = gitolitePath;
        serviceConfig = asServer // {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "git-server-configure" ''
            set -eu
            base="${dataDir}/.gitolite"
            ${pkgs.coreutils}/bin/install -d -m 0700 "$base/conf"
            ${pkgs.coreutils}/bin/install -m 0600 ${gitoliteConfiguration} "$base/conf/gitolite.conf"
            ${pkgs.coreutils}/bin/rm -rf "$base/keydir"
            ${pkgs.coreutils}/bin/cp -rL ${keydir} "$base/keydir"
            ${pkgs.coreutils}/bin/chmod -R u+w "$base/keydir"
            ${pkgs.gitolite}/bin/gitolite setup --hooks-only
            ${pkgs.gitolite}/bin/gitolite compile
            ${pkgs.gitolite}/bin/gitolite trigger POST_COMPILE
          '';
        };
      };

      # The Git service: one sshd per connection on the Git port. Stopping
      # git-server.socket takes this server out of the cluster; starting it
      # first runs the return.
      systemd.sockets.git-server = {
        # It listens only after the return, which waits for the network, so
        # it stays out of sockets.target and its early ordering.
        description = "The cluster's Git over SSH";
        wantedBy = [ "multi-user.target" ];
        unitConfig.DefaultDependencies = false;
        requires = [ "sysinit.target" ];
        wants = [ "git-server-return.service" ];
        after = [
          "sysinit.target"
          "git-server-return.service"
          "git-server-configure.service"
        ];
        before = [ "shutdown.target" ];
        conflicts = [ "shutdown.target" ];
        socketConfig = {
          ListenStream = cfg.port;
          Accept = true;
        };
      };
      systemd.services."git-server@" = {
        description = "Git over SSH, one connection";
        serviceConfig = {
          ExecStart = "${config.services.openssh.package}/bin/sshd -i -f ${sshdConfiguration}";
          StandardInput = "socket";
          StandardError = "journal";
        };
      };
      networking.firewall.allowedTCPPorts = [ cfg.port ];

      systemd.services.git-server-return = {
        description = "Announce this Git server to the others and fetch what landed while it was gone";
        after = [
          "network-online.target"
          "git-server-configure.service"
        ];
        wants = [ "network-online.target" ];
        requires = [ "git-server-configure.service" ];
        environment = serviceEnvironment;
        path = gitolitePath;
        serviceConfig = asServer // {
          Type = "oneshot";
          LoadCredential = "host-key:${hostKey}";
          ExecStart = returnToCluster;
        };
      };

      systemd.paths.git-server-mirror = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.DirectoryNotEmpty = mirrorQueue;
      };
      systemd.services.git-server-mirror = {
        description = "Carry the primary's received pushes to the other Git servers";
        environment = serviceEnvironment;
        serviceConfig = asServer // {
          Type = "oneshot";
          LoadCredential = "host-key:${hostKey}";
          ExecStart = mirror;
        };
      };

      # Promotion: a user's write that found the primary unreachable arms one
      # timer; a word from another server disarms it; its expiry promotes.
      systemd.paths.git-server-primary-unreachable = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathModified = "${eventsDir}/primary-unreachable";
      };
      systemd.services.git-server-primary-unreachable = {
        description = "Arm the promotion of this standby";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl start git-server-promote.timer";
        };
      };
      systemd.paths.git-server-peer-alive = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathModified = "${eventsDir}/peer-alive";
      };
      systemd.services.git-server-peer-alive = {
        description = "Disarm the promotion of this standby: another server is alive";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl stop git-server-promote.timer";
        };
      };
      systemd.timers.git-server-promote = {
        description = "Promote this standby when the primary stays unreachable";
        timerConfig = {
          OnActiveSec = cfg.promotionDelay;
          RemainAfterElapse = false;
        };
      };
      systemd.services.git-server-promote = {
        description = "Take the cluster's Git writes on this standby";
        serviceConfig = asServer // {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "git-server-promote" ''
            echo primary > ${roleFile}
            echo "promoted: this server takes the cluster's Git writes"
          '';
        };
      };
    })

    (mkIf (preferredServer != null) {
      # Every node reaches the cluster's Git by its name as the git user, so a
      # remote or a flake input names it bare: git+ssh://<domain>/<repo>.
      programs.ssh.extraConfig = ''
        Host ${gitDomain}
          User ${serverUser}
          Port ${toString cfg.port}
          ProxyCommand ${connect} %p
      '';
      programs.ssh.knownHosts = lib.listToAttrs (
        map (entry: {
          name = "git-server-${entry.name}";
          value = {
            hostNames = [
              "[${gitDomain}]:${toString cfg.port}"
              "[${entry.criomeDomainName}]:${toString cfg.port}"
            ];
            publicKey = entry.sshPublicKeyLine;
          };
        }) servers
      );
    })
  ];
}
