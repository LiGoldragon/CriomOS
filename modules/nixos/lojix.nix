{
  config,
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib) mkDefault mkIf;

  nodeServices = import ./node-services.nix { inherit lib; };
  services = horizon.node.services or [ ];
  lojixEnabled = nodeServices.has services "PersonaDevelopment";

  operatorUser = "li";
  operatorGroup = "users";
  operatorUid = config.users.users.${operatorUser}.uid;
  lojixPackage = inputs.lojix.packages.${pkgs.stdenv.hostPlatform.system}.default;

  runtimeDirectory = "/run/lojix";
  stateDirectory = "/var/lib/lojix";
  ordinarySocket = "${runtimeDirectory}/ordinary.sock";
  ownerSocket = "${runtimeDirectory}/owner.sock";
  startupArchive = "${runtimeDirectory}/startup.rkyv";
  # A production node bakes no test-op fixture: field 7 is `NoTestDefaults`, so
  # the daemon's `test_defaults` lowers to `None` and a bare `(Check …)`/`(Run
  # …)` is rejected with `NoTestDefaults` rather than silently building a
  # per-node baked test cluster. The test fixture (test_flake, its cluster,
  # host, mode) is supplied only by the test invocation that runs the op — never
  # per-node here. Deployment-independence discipline (micro-components skill:
  # test clusters and fixtures live only in test code). Requires a pinned lojix
  # carrying the optional-`test_defaults` shape (`WriterTestDefaultsChoice`).
  startupRequest = pkgs.writeText "lojix-daemon-configuration.nota" ''
    (ConfigurationWriteRequest (${ordinarySocket} 432 ${ownerSocket} 384 ${stateDirectory} ${config.networking.hostName} NoTestDefaults ${startupArchive}))
  '';
in
{
  config = mkIf lojixEnabled {
    assertions = [
      {
        assertion = builtins.hasAttr operatorUser config.users.users;
        message = "lojix-daemon requires the local operator user '${operatorUser}' on PersonaDevelopment nodes";
      }
    ];

    users.users.${operatorUser}.uid = mkDefault 1001;

    environment.systemPackages = [ lojixPackage ];

    systemd.services.lojix-daemon = {
      description = "lojix deploy orchestrator daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.coreutils
        pkgs.hostname
        pkgs.gitMinimal
        pkgs.nix
        pkgs.openssh
      ];
      environment = {
        SSH_AUTH_SOCK = "/run/user/${toString operatorUid}/gnupg/S.gpg-agent.ssh";
      };
      serviceConfig = {
        Type = "simple";
        User = operatorUser;
        Group = operatorGroup;
        WorkingDirectory = stateDirectory;
        RuntimeDirectory = "lojix";
        RuntimeDirectoryMode = "0750";
        StateDirectory = "lojix";
        StateDirectoryMode = "0750";
        ExecStartPre = "${lojixPackage}/bin/lojix-write-configuration ${startupRequest}";
        ExecStart = "${lojixPackage}/bin/lojix-daemon ${startupArchive}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
