{ inputs, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  expectedRevision = "54710fabbab7c47ce19764a98e7153e5c93a49f4";
  expectedHomeRevision = "50d9ac8bdf90fc6b42365d4210638484f53be4c6";
  expectedSchemaRustRevision = "37b7d1035a472a15081f3e2e8a93b95bf733c3ee";
  rootLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  homeLock = builtins.fromJSON (builtins.readFile "${inputs.criomos-home}/flake.lock");
  lojix = inputs.lojix.packages.${system}.default;
  bootstrap = inputs.lojix.packages.${system}.lojix-bootstrap;
  homeClient = inputs.criomos-home.packages.${system}.lojix-client;
  homeBootstrap = inputs.criomos-home.packages.${system}.lojix-bootstrap;
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
  homeActivation = fixture.config.systemd.services.home-manager-li;
  homeActivationPackage = fixture.config."home-manager".users.li.home.activationPackage;
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
assert homeLock.nodes.lojix.locked.rev == expectedRevision;
assert rootLock.nodes."criomos-home".inputs.lojix == [ "lojix" ];
assert rootLock.nodes."criomos-home".locked.rev == expectedHomeRevision;
assert rootLock.nodes."schema-rust-source".locked.rev == expectedSchemaRustRevision;
assert homeLock.nodes."schema-rust-source".locked.rev == expectedSchemaRustRevision;
assert fixture.config.services.lojix.package == lojix;
assert homeClient == lojix;
assert homeBootstrap == bootstrap;
assert fixture.config.services.lojix.user == "li";
assert fixture.config.services.lojix.user == fixture.config.users.users.li.name;
assert fixture.config.services.lojix.group == fixture.config.users.users.li.group;
assert fixture.config.users.users.li.group == "users";
assert builtins.attrNames fixture.config."home-manager".users == [ "li" ];
assert homeActivationPackage.drvPath != "";
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
assert builtins.elem "lojix-daemon.service" homeActivation.requires;
assert builtins.elem "lojix-daemon.service" homeActivation.after;
pkgs.runCommand "lojix-ownership"
  {
    inherit
      lojix
      bootstrap
      homeClient
      homeBootstrap
      ;
    daemonCommand = daemon.serviceConfig.ExecStart;
    writerCommand = builtins.elemAt daemon.serviceConfig.ExecStartPre 0;
  }
  ''
    test -x "$lojix/bin/lojix"
    test -x "$bootstrap/bin/lojix-bootstrap"
    test "$homeClient" = "$lojix"
    test "$homeBootstrap" = "$bootstrap"
    test "$(printf '%s' "$daemonCommand")" = "${lojix}/bin/lojix-daemon /run/lojix/startup.rkyv"
    test "$(printf '%s' "$writerCommand")" = \
      "${lojix}/bin/lojix-write-configuration 'ConfigurationWriteRequest.{/run/lojix/ordinary.sock 432 /run/lojix/owner.sock 384 /var/lib/lojix /var/lib/lojix/lojix.sema lojix-ownership-fixture 2700 NoTestDefaults /run/lojix/startup.rkyv}'"
    touch "$out"
  ''
