{ inputs, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  expectedRevision = "c4bba4fa12408c39ff745b0773468cd32a74403f";
  expectedPackageName = "lojix-6.0.0";
  expectedHomeRevision = "f652ba9ae6b24b7e946e60e98acc270280beb774";
  expectedOrchestrateRevision = "9070cbb8717813b127e448dd5a43a2095daf7d1b";
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
    size = "Min";
    trust = "Min";
    keyboard = "Colemak";
    style = "Emacs";
    githubId = name;
    publicKeys =
      if hasPublicKey then
        [
          {
            node = "lojix-ownership-fixture";
            ssh = "fixture-ssh-key";
            keygrip = "fixture-keygrip";
          }
        ]
      else
        [ ];
    emailAddress = "${name}@example.invalid";
    matrixId = "@${name}:example.invalid";
    gitSigningKey = if hasPublicKey then "&fixture-keygrip" else null;
    useColemak = true;
    useFastRepeat = true;
    isMultimediaDev = false;
    isCodeDev = true;
    preferredEditor = "Emacs";
    textSize = "Medium";
    resolvedTextSize = "Medium";
    sshPublicKeys = lib.optional hasPublicKey "ssh-ed25519 fixture-ssh-key";
    sshPublicKey = if hasPublicKey then "ssh-ed25519 fixture-ssh-key" else null;
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
      capabilities = [
        {
          kind = "personaDevelopment";
          capabilities = [ ];
        }
      ];
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
  nexus = fixture.config.systemd.services.lojix;
  codexRemoteControl =
    fixture.config.home-manager.users.li.systemd.user.services.codex-remote-control;
  liHomeActivation = fixture.config.home-manager.users.li.home.activationPackage;
  servicePathEnvironment =
    service: lib.makeBinPath service.path + ":" + lib.makeSearchPath "sbin" service.path;
  nexusEnvironment = nexus.environment;
  localUserName = fixture.config.services.lojix.user;
  localUserUid = fixture.config.users.users.${localUserName}.uid;
  expectedRuntimeSshAuthSocket = "/run/user/$(${pkgs.coreutils}/bin/id -u)/gnupg/S.gpg-agent.ssh";
  expectedNexusCommand = "${lojix}/bin/lojix-nexus";
  explicitSshAuthSocket = "/run/user/explicit/gnupg/S.gpg-agent.ssh";
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
          stateDirectoryPath = "/var/lib/lojix-explicit";
          runtimeDirectoryPath = "/run/lojix-explicit";
          nexusHost = "lojix-explicit";
          sshAuthSocket = {
            mode = "path";
            path = explicitSshAuthSocket;
          };
        };
      }
    ];
  };
  explicitSocketNexus = explicitSocketFixture.config.systemd.services.lojix;
  invalidIdentityFixture =
    users:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          node.capabilities = [
            {
              kind = "personaDevelopment";
              capabilities = [ ];
            }
          ];
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
assert lojix.name == expectedPackageName;
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
# Claude Remote Control is removed from Home: no user gets a persistent
# Claude session owner, and no per-user working root is projected for one.
assert !(fixture.config.home-manager.users.li.systemd.user.services ? claude-remote-control);
assert
  !(multiUserHomeFixture.config.home-manager.users.li.systemd.user.services ? claude-remote-control);
assert
  !(
    multiUserHomeFixture.config.home-manager.users.remote.systemd.user.services ? claude-remote-control
  );
assert codexRemoteControl.Service.WorkingDirectory == "/home/li/primary";
assert
  multiUserHomeFixture.config.home-manager.users.li.systemd.user.services.codex-remote-control.Service.WorkingDirectory
  == "/home/li/primary";
assert
  multiUserHomeFixture.config.home-manager.users.remote.systemd.user.services.codex-remote-control.Service.WorkingDirectory
  == "/home/remote/primary";
assert localUserUid == null;
assert
  fixture.config.services.lojix.sshAuthSocket == {
    mode = "service-user-gpg-agent";
    path = null;
  };
assert
  nexusEnvironment == {
    PATH = servicePathEnvironment nexus;
  };
assert nexus.serviceConfig.User == localUserName;
assert
  explicitSocketNexus.environment == {
    PATH = servicePathEnvironment explicitSocketNexus;
    SSH_AUTH_SOCK = explicitSshAuthSocket;
  };
# An explicit SSH-agent path needs no wrapper, so this one starts the Nexus
# directly - still with no argument.
assert explicitSocketNexus.serviceConfig.ExecStart == "${lojix}/bin/lojix-nexus";
assert builtins.attrNames fixture.config."home-manager".users == [ "li" ];
assert builtins.any (
  assertion:
  !assertion.assertion
  &&
    assertion.message
    == "PersonaDevelopment Lojix identity requires exactly one projected local horizon.users user (hasPublicKey); found none"
) noLocalUserAssertions;
assert builtins.any (
  assertion:
  !assertion.assertion
  &&
    assertion.message
    == "PersonaDevelopment Lojix identity requires exactly one projected local horizon.users user (hasPublicKey); found multiple: alpha, beta"
) multipleLocalUserAssertions;
assert fixture.config.services.lojix.ordinarySocketPath == "/run/lojix/ordinary.sock";
assert fixture.config.services.lojix.ordinarySocketMode == 432;
assert fixture.config.services.lojix.ownerSocketPath == "/run/lojix/meta.sock";
assert fixture.config.services.lojix.ownerSocketMode == 384;
assert fixture.config.services.lojix.stateDirectoryPath == "/var/lib/lojix";
assert fixture.config.services.lojix.storePath == "/var/lib/lojix/lojix.sema";
assert fixture.config.services.lojix.runtimeDirectoryPath == "/run/lojix";
assert
  fixture.config.services.lojix.resetConfigurationPath == "/var/lib/lojix/reset-configuration.rkyv";
assert !(builtins.hasAttr "effectTimeoutSeconds" fixture.config.services.lojix);
assert
  !(builtins.elem "lojix.service" (fixture.config.systemd.services.home-manager-li.requires or [ ]));
assert
  !(builtins.elem "lojix.service" (fixture.config.systemd.services.home-manager-li.after or [ ]));
pkgs.runCommand "lojix-ownership"
  {
    inherit
      lojix
      homeProjectionBoundary
      liHomeActivation
      ;
    nexusWrapper = nexus.serviceConfig.ExecStart;
  }
  ''
    test -x "$lojix/bin/lojix"
    test -x "$lojix/bin/lojix-meta"
    test -e "$homeProjectionBoundary"
    test -e "$liHomeActivation"
    test -x "$nexusWrapper"
    grep -F ${lib.escapeShellArg "export SSH_AUTH_SOCK=${expectedRuntimeSshAuthSocket}"} "$nexusWrapper"
    grep -F ${lib.escapeShellArg "exec ${expectedNexusCommand}"} "$nexusWrapper"
    touch "$out"
  ''
