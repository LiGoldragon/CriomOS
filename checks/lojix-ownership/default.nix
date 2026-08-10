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
      {
        system.stateVersion = "26.05";
        networking.hostName = "lojix-ownership-fixture";
        users.groups.lojix-fixture = { };
        users.users.lojix-fixture = {
          isSystemUser = true;
          group = "lojix-fixture";
        };
        services.lojix = {
          enable = true;
          user = "lojix-fixture";
          group = "lojix-fixture";
        };
        home-manager.users.lojix-fixture = {
          home.stateVersion = "26.05";
          home.homeDirectory = "/var/empty";
          home.username = "lojix-fixture";
        };
      }
    ];
  };
  daemon = fixture.config.systemd.services.lojix-daemon;
  homeActivation = fixture.config.systemd.services.home-manager-lojix-fixture;
in
assert rootLock.nodes.lojix.locked.rev == expectedRevision;
assert homeLock.nodes.lojix.locked.rev == expectedRevision;
assert rootLock.nodes."criomos-home".inputs.lojix == [ "lojix" ];
assert fixture.config.services.lojix.package == lojix;
assert lojix == homeClient;
assert bootstrap == homeBootstrap;
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
  }
  ''
    test -x "$lojix/bin/lojix"
    test -x "$bootstrap/bin/lojix-bootstrap"
    test "$lojix" = "$homeClient"
    test "$bootstrap" = "$homeBootstrap"
    test "$(printf '%s' "$daemonCommand")" = "${lojix}/bin/lojix-daemon /run/lojix/startup.rkyv"
    touch "$out"
  ''
