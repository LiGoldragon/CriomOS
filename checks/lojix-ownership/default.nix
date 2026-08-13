{ inputs, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  expectedRevision = "7693ad3e8814cbea68ea6491d6a10f04d5cb2979";
  expectedHomeRevision = "e5f2264693c83f31f9991f1f12e2c60e2cdcb4a9";
  expectedOrchestrateRevision = "45283e2120e930e62dabdaf650e704a425be804c";
  expectedSchemaRustRevision = "37b7d1035a472a15081f3e2e8a93b95bf733c3ee";
  rootLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  homeLock = builtins.fromJSON (builtins.readFile "${inputs.criomos-home}/flake.lock");
  lojix = inputs.lojix.packages.${system}.default;
  homePackages = inputs.criomos-home.packages.${system} or { };
  homeApps = inputs.criomos-home.apps.${system} or { };
  homeChecks = inputs.criomos-home.checks.${system} or { };
  homeProjectionBoundary = homeChecks.system-projection-boundary;
  mkProjectedUser = name: hasPubKey: {
    inherit hasPubKey name;
    species = "Code";
    size = {
      min = true;
      medium = false;
      large = false;
      max = false;
    };
    trust = {
      min = true;
      medium = false;
      large = false;
      max = false;
    };
    keyboard = "Colemak";
    style = "Emacs";
    githubId = name;
    pubKeys =
      if hasPubKey then
        {
          "lojix-ownership-fixture".keygrip = "fixture-keygrip";
        }
      else
        { };
    emailAddress = "${name}@example.invalid";
    matrixId = "@${name}:example.invalid";
    gitSigningKey = if hasPubKey then "&fixture-keygrip" else null;
    useColemak = true;
    useFastRepeat = true;
    isMultimediaDev = false;
    isCodeDev = true;
    preferredEditor = "Emacs";
    textSize = "Medium";
    sshPubKeys = [ ];
    sshPubKey = null;
    extraGroups = [ ];
    enableLinger = false;
  };
  horizon = {
    node = {
      name = "lojix-ownership-fixture";
      adminSshPubKeys = [ ];
      behavesAs = {
        edge = false;
        largeAi = false;
      };
      typeIs.largeAiRouter = false;
      machine.model = "fixture";
      services = [ "PersonaDevelopment" ];
    };
    exNodes = { };
    users = {
      li = mkProjectedUser "li" true;
      remote = mkProjectedUser "remote" false;
    };
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
        system.stateVersion = "26.05";
        networking.hostName = "lojix-ownership-fixture";
      }
    ];
  };
  daemon = fixture.config.systemd.services.lojix-daemon;
  invalidIdentityFixture =
    users:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          node.services = [ "PersonaDevelopment" ];
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
  noLocalUserAssertions = (invalidIdentityFixture { }).config.assertions;
  multipleLocalUserAssertions =
    (invalidIdentityFixture {
      alpha.hasPubKey = true;
      beta.hasPubKey = true;
    }).config.assertions;
in
assert rootLock.nodes.lojix.locked.rev == expectedRevision;
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
assert builtins.attrNames fixture.config."home-manager".users == [ "li" ];
assert builtins.any (
  assertion:
  !assertion.assertion
  &&
    assertion.message
    == "PersonaDevelopment Lojix identity requires exactly one projected local horizon.users user (hasPubKey); found none"
) noLocalUserAssertions;
assert builtins.any (
  assertion:
  !assertion.assertion
  &&
    assertion.message
    == "PersonaDevelopment Lojix identity requires exactly one projected local horizon.users user (hasPubKey); found multiple: alpha, beta"
) multipleLocalUserAssertions;
assert fixture.config.services.lojix.ordinarySocketPath == "/run/lojix/ordinary.sock";
assert fixture.config.services.lojix.ordinarySocketMode == 432;
assert fixture.config.services.lojix.ownerSocketPath == "/run/lojix/owner.sock";
assert fixture.config.services.lojix.ownerSocketMode == 384;
assert fixture.config.services.lojix.stateDirectoryPath == "/var/lib/lojix";
assert fixture.config.services.lojix.storePath == "/var/lib/lojix/lojix.sema";
assert fixture.config.services.lojix.startupArchivePath == "/run/lojix/startup.rkyv";
assert fixture.config.services.lojix.effectTimeoutSeconds == 2700;
assert !(builtins.elem "lojix-daemon.service" (fixture.config.systemd.services.home-manager-li.requires or [ ]));
assert !(builtins.elem "lojix-daemon.service" (fixture.config.systemd.services.home-manager-li.after or [ ]));
pkgs.runCommand "lojix-ownership"
  {
    inherit
      lojix
      homeProjectionBoundary
      ;
    daemonCommand = daemon.serviceConfig.ExecStart;
    writerCommand = builtins.elemAt daemon.serviceConfig.ExecStartPre 0;
  }
  ''
    test -x "$lojix/bin/lojix"
    test -e "$homeProjectionBoundary"
    test "$(printf '%s' "$daemonCommand")" = "${lojix}/bin/lojix-daemon /run/lojix/startup.rkyv"
    test "$(printf '%s' "$writerCommand")" = \
      "${lojix}/bin/lojix-write-configuration 'ConfigurationWriteRequest.{/run/lojix/ordinary.sock 432 /run/lojix/owner.sock 384 /var/lib/lojix /var/lib/lojix/lojix.sema lojix-ownership-fixture 2700 NoTestDefaults /run/lojix/startup.rkyv}'"
    touch "$out"
  ''
