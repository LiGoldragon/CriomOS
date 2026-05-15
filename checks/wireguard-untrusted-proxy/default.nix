{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  constants = inputs.criomos-lib.lib.constants;

  configuration = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit constants;
      horizon = {
        node = {
          nodeIp = "10.18.0.9/32";
          hasWireguardPubKey = true;
          wireguardUntrustedProxies = [
            {
              publicKey = "proxy-public-key";
              endpoint = "proxy.example.test:51820";
              interfaceIp = "10.77.0.2/32";
            }
          ];
        };
        exNodes = { };
      };
    };
    modules = [
      ../../modules/nixos/network/wireguard.nix
    ];
  };

  proxyInterface = configuration.config.networking.wireguard.interfaces.wgProxies;
  proxyPeer = builtins.head proxyInterface.peers;
in
pkgs.runCommand "wireguard-untrusted-proxy-check" { } ''
  set -eu

  test ${lib.escapeShellArg proxyPeer.publicKey} = proxy-public-key
  test ${lib.escapeShellArg proxyPeer.endpoint} = proxy.example.test:51820
  test ${lib.escapeShellArg (builtins.toJSON proxyPeer.allowedIPs)} = '["0.0.0.0/0"]'
  test ${lib.escapeShellArg (builtins.toJSON proxyInterface.ips)} = '["10.77.0.2/32"]'

  touch "$out"
''
