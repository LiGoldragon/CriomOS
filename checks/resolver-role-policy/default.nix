{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  constants = inputs.criomos-lib.lib.constants;

  baseBehaviors = {
    bareMetal = false;
    center = false;
    edge = false;
    iso = false;
    largeAi = false;
    router = false;
  };

  baseNode = {
    name = "edge-test";
    criomeDomainName = "edge-test.goldragon.criome";
    enableNetworkManager = true;
    hasNordvpnPubKey = false;
    hasWifiCertPubKey = false;
    hasWireguardPubKey = false;
    hasYggPubKey = false;
    isNixCache = false;
    linkLocalIps = [ ];
    nixCacheDomain = null;
    nodeIp = "10.18.0.50";
    wireguardPubKey = "";
    wireguardUntrustedProxies = [ ];
    yggAddress = "200:db8::50";
    behavesAs = baseBehaviors // {
      edge = true;
    };
  };

  routerNode = baseNode // {
    name = "router-test";
    criomeDomainName = "router-test.goldragon.criome";
    enableNetworkManager = false;
    nodeIp = constants.network.lan.gateway;
    yggAddress = "200:db8::1";
    behavesAs = baseBehaviors // {
      router = true;
    };
  };

  peerNode = baseNode // {
    name = "peer-test";
    criomeDomainName = "peer-test.goldragon.criome";
    nodeIp = "10.18.0.51";
    yggAddress = "200:db8::51";
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants inputs;
        horizon = {
          cluster.name = "goldragon";
          inherit node;
          exNodes = {
            peer-test = peerNode;
          };
        };
      };
      modules = [
        ../../modules/nixos/network/default.nix
      ];
    };

  desktopConfiguration = configurationFor baseNode;
  routerConfiguration = configurationFor routerNode;

  desktopUnboundEnabled =
    if desktopConfiguration.config.services.unbound.enable then "true" else "false";
  desktopResolvedEnabled =
    if desktopConfiguration.config.services.resolved.enable then "true" else "false";
  desktopNetworkManagerDns = desktopConfiguration.config.networking.networkmanager.dns;
  desktopNameservers = builtins.toJSON desktopConfiguration.config.networking.nameservers;
  desktopResolvconfEnabled =
    if desktopConfiguration.config.networking.resolvconf.enable then "true" else "false";

  routerUnboundEnabled =
    if routerConfiguration.config.services.unbound.enable then "true" else "false";
  routerResolvedEnabled =
    if routerConfiguration.config.services.resolved.enable then "true" else "false";
  routerUnboundInterfaces = builtins.toJSON routerConfiguration.config.services.unbound.settings.server.interface;
  routerForwardZones = builtins.toJSON routerConfiguration.config.services.unbound.settings.forward-zone;
in
pkgs.runCommand "resolver-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg desktopUnboundEnabled} = false
  test ${lib.escapeShellArg desktopResolvedEnabled} = true
  test ${lib.escapeShellArg desktopNetworkManagerDns} = systemd-resolved
  test ${lib.escapeShellArg desktopNameservers} = '[]'
  test ${lib.escapeShellArg desktopResolvconfEnabled} = false

  test ${lib.escapeShellArg routerUnboundEnabled} = true
  test ${lib.escapeShellArg routerResolvedEnabled} = false
  echo ${lib.escapeShellArg routerUnboundInterfaces} | grep -F ${lib.escapeShellArg constants.network.lan.gateway}
  ! echo ${lib.escapeShellArg routerForwardZones} | grep -F 'tailnet.goldragon.criome.'

  touch "$out"
''
