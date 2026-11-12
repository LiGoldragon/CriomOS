{ inputs, pkgs, ... }:
let
  lib = pkgs.lib;
  evaluation = import (inputs.nixpkgs + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = {
      constants = { };
      horizon.users = {
        first = {
          hasPublicKey = true;
          capabilities = [ ];
        };
        second = {
          hasPublicKey = true;
          capabilities = [ ];
        };
        absent = {
          hasPublicKey = false;
          capabilities = [ ];
        };
      };
      inputs = inputs // {
        criomos-home = {
          horizonUsersByName = users: users;
          homeModules.default = { lib, ... }: {
            options.criomosHome = {
              curriculum.enable = lib.mkEnableOption "fixture curriculum";
              codexNextCandidate.enable = lib.mkEnableOption "fixture candidate";
            };
          };
        };
      };
    };
    modules = [
      inputs.home-manager.nixosModules.home-manager
      ../../modules/nixos/userHomes.nix
      {
        system.stateVersion = "26.05";
        users.users.first = {
          isNormalUser = true;
          home = "/home/first";
        };
        users.users.second = {
          isNormalUser = true;
          home = "/home/second";
        };
      }
    ];
  };
  cfg = evaluation.config;
  names = [
    "first"
    "second"
  ];
  valid =
    name:
    let
      service = cfg.systemd.services."home-manager-${name}";
      unit = cfg.systemd.units."home-manager-${name}.service".text;
    in
    assert service.serviceConfig.PrivateTmp;
    assert !service.serviceConfig.RemainAfterExit;
    assert service.serviceConfig.TimeoutStartSec == "20min";
    assert lib.hasInfix "RemainAfterExit=false" unit;
    assert lib.hasInfix "PrivateTmp=true" unit;
    assert lib.hasInfix "TimeoutStartSec=20min" unit;
    assert service.serviceConfig.Type == "oneshot";
    true;
in
assert builtins.all valid names;
assert !(cfg.systemd.services ? home-manager-absent);
pkgs.runCommand "home-manager-unit-lifetime-check" { } ''
  touch "$out"
''
