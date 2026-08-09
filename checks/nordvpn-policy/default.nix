{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  constants = {
    fileSystem.nordvpn.privateKeyFile = "/run/keys/nordvpn";
  };

  configuration = lib.nixosSystem {
    inherit system;
    specialArgs = {
      horizon.node.hasNordvpnPubKey = true;
      inherit constants;
    };
    modules = [ ../../modules/nixos/network/nordvpn.nix ];
  };

  service = configuration.config.systemd.services.nordvpn-connections;
  generator = pkgs.writeText "nordvpn-connection-generator" service.script;
  dispatcherScripts = configuration.config.networking.networkmanager.dispatcherScripts;
  lockPath = ../../data/config/nordvpn/servers-lock.json;
  lock = builtins.fromJSON (builtins.readFile lockPath);
  serverCount = builtins.length lock.servers;
  triggerPaths = builtins.map builtins.toString service.restartTriggers;
in
pkgs.runCommand "nordvpn-policy" { } ''
  set -eu

  test ${toString serverCount} = 6
  test ${lib.escapeShellArg (builtins.toJSON dispatcherScripts)} = '[]'
  test ${lib.escapeShellArg (builtins.toJSON triggerPaths)} = '["${toString lockPath}"]'

  test "$(grep -Fc 'autoconnect=false' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'fwmark=51820' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'ip4-auto-default-route=true' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'ip6-auto-default-route=false' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'allowed-ips=0.0.0.0/0;' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'persistent-keepalive=25;' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'dns-search=~.;' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'dns-priority=-50' ${lib.escapeShellArg generator})" = 6
  test "$(grep -Fc 'never-default=false' ${lib.escapeShellArg generator})" = 6
  ! grep -Fq '::/0' ${lib.escapeShellArg generator}
  ! grep -Fq 'ip rule add' ${lib.escapeShellArg generator}
  ! grep -Fq '2>/dev/null || true' ${lib.escapeShellArg generator}

  touch "$out"
''
