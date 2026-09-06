{ inputs, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  # The final Datom/Horizon producer set owns the only Lojix package pin.
  # Home follows that package boundary and shares the maintained Orchestrate
  # release instead of carrying a second daemon/client dependency.
  expectedRevision = "7e29c37f51092e5a20abf88c670aabd2acee6e52";
  expectedVersion = "0.21.0";
  expectedHomeRevision = "be20529823792d525659053399c31c040ce94bfb";
  expectedOrchestrateRevision = "ac8a92666f4abd8356522c4d52ab23ddcdff4c15";
  expectedSchemaRustRevision = "f3b4563163dd11ba1cbbcca8081701ab7830b8f5";
  rootLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  homeLock = builtins.fromJSON (builtins.readFile "${inputs.criomos-home}/flake.lock");
  lojix = inputs.lojix.packages.${system}.default;
  homePackages = inputs.criomos-home.packages.${system} or { };
  homeApps = inputs.criomos-home.apps.${system} or { };
  homeChecks = inputs.criomos-home.checks.${system} or { };
  homeProjectionBoundary = homeChecks.system-projection-boundary;
  mkProjectedUser = name: hasPublicKey: {
    inherit hasPublicKey name;
    role = "Unlimited";
    size = "Large";
    trust = "Max";
    keyboard = "Colemak";
    style = "Emacs";
    githubId = name;
    fastRepeat = null;
    publicKeys = [ ];
    editor = null;
    textSize = null;
    emailAddress = "${name}@example.test";
    matrixId = "@${name}:example.test";
    gitSigningKey = null;
    useColemak = true;
    useFastRepeat = false;
    isMultimediaDev = false;
    isCodeDev = true;
    preferredEditor = "Emacs";
    resolvedTextSize = "Medium";
    sshPublicKeys = [ ];
    sshPublicKey = null;
    extraGroups = [ ];
    enableLinger = false;
  };
  horizon = {
    node = {
      name = "lojix-ownership-fixture";
      adminSshPublicKeys = [ ];
      behavesAs = {
        edge = false;
        largeAi = false;
      };
      capabilities = [ "personaDevelopment" ];
    };
    exNodes = { };
    users = [
      (mkProjectedUser "li" true)
      (mkProjectedUser "remote" false)
    ];
  };
  multiUserHorizon = horizon // {
    users = [
      (mkProjectedUser "li" true)
      (mkProjectedUser "remote" true)
    ];
  };
  multiUserHomeFixture = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit inputs;
      horizon = multiUserHorizon;
      constants = inputs.criomos-lib.lib.constants;
    };
    modules = [
      inputs.home-manager.nixosModules.home-manager
      ../../modules/nixos/users.nix
      ../../modules/nixos/userHomes.nix
      {
        nixpkgs.config.allowUnfree = true;
        system.stateVersion = "26.05";
        networking.hostName = "lojix-ownership-multi-user-fixture";
      }
    ];
  };
  fixture = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit horizon inputs;
      constants = inputs.criomos-lib.lib.constants;
    };
    modules = [
      inputs.home-manager.nixosModules.home-manager
      ../../modules/nixos/lojix.nix
      ../../modules/nixos/lojix-persona-development.nix
      ../../modules/nixos/users.nix
      ../../modules/nixos/userHomes.nix
      {
        nixpkgs.config.allowUnfree = true;
        system.stateVersion = "26.05";
        networking.hostName = "lojix-ownership-fixture";
      }
    ];
  };
  daemon = fixture.config.systemd.services.lojix-daemon;
  claudeRemoteControl =
    fixture.config.home-manager.users.li.systemd.user.services.claude-remote-control;
  codexRemoteControl =
    fixture.config.home-manager.users.li.systemd.user.services.codex-remote-control;
  liHomeActivation = fixture.config.home-manager.users.li.home.activationPackage;
  servicePathEnvironment =
    service: lib.makeBinPath service.path + ":" + lib.makeSearchPath "sbin" service.path;
  daemonEnvironment = daemon.environment;
  localUserName = fixture.config.services.lojix.user;
  localUserUid = fixture.config.users.users.${localUserName}.uid;
  expectedRuntimeSshAuthSocket = "/run/user/$(${pkgs.coreutils}/bin/id -u)/gnupg/S.gpg-agent.ssh";
  expectedDaemonCommand = "${lojix}/bin/lojix-daemon /run/lojix/startup.rkyv";
  explicitSshAuthSocket = "/run/user/explicit/gnupg/S.gpg-agent.ssh";
  explicitSocketExpectedDaemonCommand = "${lojix}/bin/lojix-daemon /run/lojix-explicit/startup.rkyv";
  explicitSocketFixture = lib.nixosSystem {
    inherit system;
    modules = [
      ../../modules/nixos/lojix.nix
      {
        system.stateVersion = "26.05";
        users.groups.lojix-explicit = { };
        users.users.lojix-explicit = {
          isNormalUser = true;
          group = "lojix-explicit";
        };
        services.lojix = {
          enable = true;
          package = lojix;
          user = "lojix-explicit";
          group = "lojix-explicit";
          ordinarySocketPath = "/run/lojix-explicit/ordinary.sock";
          ordinarySocketMode = 432;
          ownerSocketPath = "/run/lojix-explicit/owner.sock";
          ownerSocketMode = 384;
          stateDirectoryPath = "/var/lib/lojix-explicit";
          storePath = "/var/lib/lojix-explicit/lojix.sema";
          startupArchivePath = "/run/lojix-explicit/startup.rkyv";
          daemonHost = "lojix-explicit";
          sshAuthSocket = {
            mode = "path";
            path = explicitSshAuthSocket;
          };
        };
      }
    ];
  };
  explicitSocketDaemon = explicitSocketFixture.config.systemd.services.lojix-daemon;
  invalidIdentityFixture =
    users:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          node.capabilities = [ "personaDevelopment" ];
          inherit users;
        };
      };
      modules = [
        ../../modules/nixos/lojix.nix
        ../../modules/nixos/lojix-persona-development.nix
        {
          system.stateVersion = "26.05";
        }
      ];
    };
  noLocalUserAssertions = (invalidIdentityFixture [ ]).config.assertions;
  multipleLocalUserAssertions =
    (invalidIdentityFixture [
      (mkProjectedUser "alpha" true)
      (mkProjectedUser "beta" true)
    ]).config.assertions;
in
assert rootLock.nodes.lojix.locked.rev == expectedRevision;
assert lojix.version == expectedVersion;
assert rootLock.nodes."criomos-home".locked.rev == expectedHomeRevision;
assert !(builtins.hasAttr "lojix" (rootLock.nodes."criomos-home".inputs or { }));
assert !(builtins.hasAttr "lojix" homeLock.nodes);
assert rootLock.nodes.orchestrate.locked.rev == expectedOrchestrateRevision;
assert homeLock.nodes.orchestrate.locked.rev == expectedOrchestrateRevision;
assert rootLock.nodes."schema-rust-source".locked.rev == expectedSchemaRustRevision;
assert homeLock.nodes."schema-rust-source".locked.rev == expectedSchemaRustRevision;
assert fixture.config.services.lojix.package == lojix;
assert !(builtins.hasAttr "lojix" homePackages);
assert !(builtins.hasAttr "lojix-client" homePackages);
assert !(builtins.hasAttr "lojix-bootstrap" homePackages);
assert !(builtins.hasAttr "lojix" homeApps);
assert !(builtins.hasAttr "lojix-bootstrap" homeApps);
assert !(builtins.hasAttr "lojix-ownership" homeChecks);
assert fixture.config.services.lojix.user == "li";
assert fixture.config.services.lojix.user == fixture.config.users.users.li.name;
assert fixture.config.services.lojix.group == fixture.config.users.users.li.group;
assert fixture.config.users.users.li.group == "users";
assert claudeRemoteControl.Service.WorkingDirectory == "/home/li/primary";
assert
  multiUserHomeFixture.config.home-manager.users.li.systemd.user.services.claude-remote-control.Service.WorkingDirectory
  == "/home/li/primary";
assert
  multiUserHomeFixture.config.home-manager.users.remote.systemd.user.services.claude-remote-control.Service.WorkingDirectory
  == "/home/remote/primary";
assert codexRemoteControl.Service.WorkingDirectory == "/home/li/primary";
assert
  multiUserHomeFixture.config.home-manager.users.li.systemd.user.services.codex-remote-control.Service.WorkingDirectory
  == "/home/li/primary";
assert
  multiUserHomeFixture.config.home-manager.users.remote.systemd.user.services.codex-remote-control.Service.WorkingDirectory
  == "/home/remote/primary";
assert claudeRemoteControl.Service.Restart == "always";
assert claudeRemoteControl.Service.UMask == "0077";
assert localUserUid == null;
assert
  fixture.config.services.lojix.sshAuthSocket == {
    mode = "service-user-gpg-agent";
    path = null;
  };
assert
  daemonEnvironment == {
    PATH = servicePathEnvironment daemon;
  };
assert daemon.serviceConfig.User == localUserName;
assert
  explicitSocketDaemon.environment == {
    PATH = servicePathEnvironment explicitSocketDaemon;
    SSH_AUTH_SOCK = explicitSshAuthSocket;
  };
assert explicitSocketDaemon.serviceConfig.ExecStart == explicitSocketExpectedDaemonCommand;
assert builtins.attrNames fixture.config."home-manager".users == [ "li" ];
assert builtins.any (
  assertion:
  !assertion.assertion
  &&
    assertion.message
    == "PersonaDevelopment Lojix identity requires exactly one projected local Horizon user (hasPublicKey); found none"
) noLocalUserAssertions;
assert builtins.any (
  assertion:
  !assertion.assertion
  &&
    assertion.message
    == "PersonaDevelopment Lojix identity requires exactly one projected local Horizon user (hasPublicKey); found multiple: alpha, beta"
) multipleLocalUserAssertions;
assert fixture.config.services.lojix.ordinarySocketPath == "/run/lojix/ordinary.sock";
assert fixture.config.services.lojix.ordinarySocketMode == 432;
assert fixture.config.services.lojix.ownerSocketPath == "/run/lojix/owner.sock";
assert fixture.config.services.lojix.ownerSocketMode == 384;
assert fixture.config.services.lojix.stateDirectoryPath == "/var/lib/lojix";
assert fixture.config.services.lojix.storePath == "/var/lib/lojix/lojix.sema";
assert fixture.config.services.lojix.startupArchivePath == "/run/lojix/startup.rkyv";
assert !(builtins.hasAttr "effectTimeoutSeconds" fixture.config.services.lojix);
assert
  !(builtins.elem "lojix-daemon.service" (
    fixture.config.systemd.services.home-manager-li.requires or [ ]
  ));
assert
  !(builtins.elem "lojix-daemon.service" (
    fixture.config.systemd.services.home-manager-li.after or [ ]
  ));
pkgs.runCommand "lojix-ownership"
  {
    inherit
      lojix
      homeProjectionBoundary
      liHomeActivation
      ;
    daemonWrapper = daemon.serviceConfig.ExecStart;
    writerCommand = builtins.elemAt daemon.serviceConfig.ExecStartPre 0;
  }
  ''
    test -x "$lojix/bin/lojix"
    test -e "$homeProjectionBoundary"
    test -e "$liHomeActivation"
    test -x "$daemonWrapper"
    grep -F ${lib.escapeShellArg "export SSH_AUTH_SOCK=${expectedRuntimeSshAuthSocket}"} "$daemonWrapper"
    grep -F ${lib.escapeShellArg "exec ${expectedDaemonCommand}"} "$daemonWrapper"
    test "$(printf '%s' "$writerCommand")" = \
      "${lojix}/bin/lojix-write-configuration 'ConfigurationWriteRequest.{/run/lojix/ordinary.sock 432 /run/lojix/owner.sock 384 /var/lib/lojix /var/lib/lojix/lojix.sema lojix-ownership-fixture NoTestDefaults /run/lojix/startup.rkyv}'"
    touch "$out"
  ''
