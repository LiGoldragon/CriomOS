{ lib, pkgs, ... }:
let
  horizon = (builtins.fromJSON (builtins.readFile ../../fixtures/horizon-projection.json)) // {
    users = [
      {
        name = "li";
        hasPublicKey = true;
      }
    ];
  };
  evaluated = lib.evalModules {
    modules = [
      ../../modules/nixos/network/zoekt-index-events.nix
      ({ lib, ... }: {
        options = {
          networking.networkmanager = {
            enable = lib.mkOption { type = lib.types.bool; };
            dispatcherScripts = lib.mkOption { type = lib.types.listOf lib.types.attrs; };
          };
          systemd.network.enable = lib.mkOption { type = lib.types.bool; };
          services.networkd-dispatcher = {
            enable = lib.mkOption { type = lib.types.bool; };
            rules = lib.mkOption { type = lib.types.attrs; };
          };
        };
        config = {
          networking.networkmanager.enable = true;
          systemd.network.enable = true;
        };
      })
    ];
    specialArgs = { inherit horizon pkgs; };
  };
  cfg = evaluated.config;
  networkManagerScript = (builtins.head cfg.networking.networkmanager.dispatcherScripts).source;
  networkdRule = cfg.services.networkd-dispatcher.rules.zoekt-index-route-up;
in
assert cfg.services.networkd-dispatcher.enable;
assert networkdRule.onState == [ "routable" ];
pkgs.runCommand "zoekt-index-events" { } ''
  grep -F 'up|vpn-up|connectivity-change|dhcp4-change|dhcp6-change)' ${networkManagerScript}
  grep -F -- '--user --machine=' ${networkManagerScript}
  grep -F 'zoekt-index-network-event.service' ${networkManagerScript}
  grep -F 'zoekt-index-drain.service' ${networkManagerScript}
  touch "$out"
''
