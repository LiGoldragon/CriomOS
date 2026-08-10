{ inputs, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  expectedRevision = "54710fabbab7c47ce19764a98e7153e5c93a49f4";
  rootLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  homeLock = builtins.fromJSON (builtins.readFile "${inputs.criomos-home}/flake.lock");
  lojix = inputs.lojix.packages.${system}.default;
  bootstrap = inputs.lojix.packages.${system}.lojix-bootstrap;
  homeClient = inputs.criomos-home.packages.${system}.lojix-client;
  homeBootstrap = inputs.criomos-home.packages.${system}.lojix-bootstrap;
  fixture = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit inputs;
      horizon = {
        node.services = [ "PersonaDevelopment" ];
      };
    };
    modules = [
      inputs.home-manager.nixosModules.home-manager
      ../../modules/nixos/lojix.nix
      ../../modules/nixos/lojix-persona-development.nix
      {
        system.stateVersion = "26.05";
        networking.hostName = "lojix-ownership-fixture";
        users.users.li = {
          isNormalUser = true;
          group = "users";
        };
        home-manager.users.li = {
          home.stateVersion = "26.05";
          home.homeDirectory = "/home/li";
          home.username = "li";
        };
      }
    ];
  };
  daemon = fixture.config.systemd.services.lojix-daemon;
  homeActivation = fixture.config.systemd.services.home-manager-li;
in
assert rootLock.nodes.lojix.locked.rev == expectedRevision;
assert homeLock.nodes.lojix.locked.rev == expectedRevision;
assert rootLock.nodes."criomos-home".inputs.lojix == [ "lojix" ];
assert fixture.config.services.lojix.package == lojix;
assert homeClient == lojix;
assert homeBootstrap == bootstrap;
assert fixture.config.services.lojix.user == "li";
assert fixture.config.services.lojix.group == "users";
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
