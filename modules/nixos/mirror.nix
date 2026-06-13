{
  config,
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib) mkIf;

  nodeServices = import ./node-services.nix { inherit lib; };
  services = horizon.node.services or [ ];
  mirrorEnabled =
    (nodeServices.has services "TailnetClient") && (nodeServices.has services "PersonaDevelopment");

  workingSocket = "/run/mirror/working.sock";
  metaSocket = "/run/mirror/meta.sock";
  storePath = "/var/lib/mirror/mirror.sema";
  daemonConfigurationPath = "/run/mirror/mirror-daemon.rkyv";
  mirrorTcpPort = 7474;
  tcpListenAddress = "0.0.0.0:${toString mirrorTcpPort}";

  daemonUser = "mirror";
  daemonGroup = "mirror";
  clientGroup = "nixdev";
  mirrorPackage = inputs.mirror.packages.${pkgs.stdenv.hostPlatform.system}.default;
  daemonConfigurationNota = pkgs.writeText "mirror-daemon-configuration.nota" ''
    (${daemonConfigurationPath} (${storePath} ${workingSocket} 432 ${metaSocket} 384 ${tcpListenAddress}))
  '';
in
{
  config = mkIf mirrorEnabled {
    environment.systemPackages = [ mirrorPackage ];

    users.groups.${daemonGroup} = { };
    users.groups.${clientGroup}.members = [ daemonUser ];

    users.users.${daemonUser} = {
      isSystemUser = true;
      group = daemonGroup;
      description = "SEMA version-control mirror daemon user";
      home = "/var/lib/mirror";
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ mirrorTcpPort ];

    systemd.services.mirror = {
      description = "SEMA version-control mirror daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "simple";
        User = daemonUser;
        Group = clientGroup;
        SupplementaryGroups = [ daemonGroup ];
        WorkingDirectory = "/var/lib/mirror";
        ExecStartPre = "${mirrorPackage}/bin/mirror-write-configuration ${daemonConfigurationNota}";
        ExecStart = "${mirrorPackage}/bin/mirror-daemon ${daemonConfigurationPath}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0007";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          "/var/lib/mirror"
          "/run/mirror"
        ];
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/mirror 2770 ${daemonUser} ${daemonGroup} -"
      "d /run/mirror 0755 ${daemonUser} ${clientGroup} -"
    ];
  };
}
