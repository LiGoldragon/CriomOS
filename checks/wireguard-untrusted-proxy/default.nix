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
        # The Horizon node network record (horizon-rs NodeNetworkView):
        # a node with a WireGuard key carries its proxies in the record.
        node.network = {
          linkLocalIps = [ ];
          nodeIp = "10.18.0.9/32";
          wireguardPublicKey = "node-public-key";
          wireguardProxies = [
            {
              publicKey = "proxy-public-key";
              endpoint = "proxy.example.test:51820";
              interfaceIp = "10.77.0.2/32";
            }
          ];
          routerInterfaces = null;
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
