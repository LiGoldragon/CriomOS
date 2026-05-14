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

  # Step 14: yggdrasil presence is a typed sub-record. Step 7a:
  # nixCache likewise. Both are null when not present.
  mkYgg = address: {
    pubKey = "0000000000000000000000000000000000000000000000000000000000000000";
    inherit address;
    subnet = "300:db8::";
  };

  # Step 7b: has_*_pub_key shadow fields are gone. Consumers gate
  # directly on `nordvpn`, `wifiCert`, `wireguardPubKey != null`,
  # `yggdrasil != null`, `nixCache != null`.
  baseNode = {
    name = "edge-test";
    criomeDomainName = "edge-test.goldragon.criome";
    enableNetworkManager = true;
    nordvpn = false;
    wifiCert = false;
    nixCache = null;
    linkLocalIps = [ "fe80::50/64" ];
    nodeIp = "10.18.0.50/32";
    services = {
      tailnet = null;
      tailnetController = null;
    };
    wireguardPubKey = null;
    wireguardUntrustedProxies = [ ];
    yggdrasil = mkYgg "200:db8::50";
    behavesAs = baseBehaviors // {
      edge = true;
    };
  };

  routerNode = baseNode // {
    name = "router-test";
    criomeDomainName = "router-test.goldragon.criome";
    enableNetworkManager = false;
    nodeIp = constants.network.lan.gateway;
    routerInterfaces = {
      wan = "wan-test0";
      wlan = "wlan-test0";
      wlanBand = "2g";
      wlanChannel = 6;
      wlanStandard = "wifi6";
    };
    yggdrasil = mkYgg "200:db8::1";
    behavesAs = baseBehaviors // {
      router = true;
    };
  };

  # Step 11: TailnetControllerRole.Server carries port only;
  # base_domain comes from cluster.tailnet.
  tailnetControllerRouterNode = routerNode // {
    services = {
      tailnet = "Client";
      tailnetController = {
        Server = {
          port = 9443;
        };
      };
    };
  };

  peerNode = baseNode // {
    name = "peer-test";
    criomeDomainName = "peer-test.goldragon.criome";
    linkLocalIps = [ "fe80::51/64" ];
    nodeIp = "10.18.0.51";
    yggdrasil = mkYgg "200:db8::51";
  };

  configurationFor =
    node: clusterExtra:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants inputs;
        horizon = {
          cluster = {
            name = "goldragon";
          } // clusterExtra;
          inherit node;
          exNodes = {
            peer-test = peerNode;
          };
        };
      };
      modules = [
        ../../modules/nixos/network/default.nix
        ../../modules/nixos/router/default.nix
      ];
    };

  desktopConfiguration = configurationFor baseNode { };
  routerConfiguration = configurationFor routerNode { };
  # Step 11: cluster.tailnet carries baseDomain for the controller node.
  tailnetControllerRouterConfiguration = configurationFor tailnetControllerRouterNode {
    tailnet = {
      baseDomain = "tailnet.fixture.test";
      tls = null;
    };
  };

  desktopUnboundEnabled =
    if desktopConfiguration.config.services.unbound.enable then "true" else "false";
  desktopResolvedEnabled =
    if desktopConfiguration.config.services.resolved.enable then "true" else "false";
  desktopNetworkManagerDns = desktopConfiguration.config.networking.networkmanager.dns;
  desktopNameservers = builtins.toJSON desktopConfiguration.config.networking.nameservers;
  desktopHosts = builtins.toJSON desktopConfiguration.config.networking.hosts;
  desktopResolvconfEnabled =
    if desktopConfiguration.config.networking.resolvconf.enable then "true" else "false";

  routerUnboundEnabled =
    if routerConfiguration.config.services.unbound.enable then "true" else "false";
  routerDnsmasqEnabled =
    if routerConfiguration.config.services.dnsmasq.enable then "true" else "false";
  routerResolvedEnabled =
    if routerConfiguration.config.services.resolved.enable then "true" else "false";
  routerDnsmasqInterfaces = builtins.toJSON routerConfiguration.config.services.dnsmasq.settings.interface;
  routerDnsmasqListenAddresses =
    builtins.toJSON
      routerConfiguration.config.services.dnsmasq.settings."listen-address";
  routerDnsmasqAddressRecords = builtins.toJSON routerConfiguration.config.services.dnsmasq.settings.address;
  routerDnsmasqServers = builtins.toJSON routerConfiguration.config.services.dnsmasq.settings.server;
  tailnetControllerRouterDnsmasqServers = builtins.toJSON tailnetControllerRouterConfiguration.config.services.dnsmasq.settings.server;
in
pkgs.runCommand "resolver-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg desktopUnboundEnabled} = false
  test ${lib.escapeShellArg desktopResolvedEnabled} = true
  test ${lib.escapeShellArg desktopNetworkManagerDns} = systemd-resolved
  test ${lib.escapeShellArg desktopNameservers} = '[]'
  echo ${lib.escapeShellArg desktopHosts} | grep -F '"edge-test.goldragon.criome"'
  echo ${lib.escapeShellArg desktopHosts} | grep -F '"wg.peer-test.goldragon.criome"'
  ! echo ${lib.escapeShellArg desktopHosts} | grep -F '/32'
  ! echo ${lib.escapeShellArg desktopHosts} | grep -F '/64'
  test ${lib.escapeShellArg desktopResolvconfEnabled} = false

  test ${lib.escapeShellArg routerUnboundEnabled} = false
  test ${lib.escapeShellArg routerDnsmasqEnabled} = true
  test ${lib.escapeShellArg routerResolvedEnabled} = false
  echo ${lib.escapeShellArg routerDnsmasqInterfaces} | grep -F br-lan
  echo ${lib.escapeShellArg routerDnsmasqListenAddresses} | grep -F ${lib.escapeShellArg constants.network.lan.gateway}
  echo ${lib.escapeShellArg routerDnsmasqAddressRecords} | grep -F '/router-test.goldragon.criome/200:db8::1'
  echo ${lib.escapeShellArg routerDnsmasqAddressRecords} | grep -F '/peer-test.goldragon.criome/200:db8::51'
  ! echo ${lib.escapeShellArg routerDnsmasqServers} | grep -F '/tailnet.goldragon.criome/100.100.100.100'
  echo ${lib.escapeShellArg tailnetControllerRouterDnsmasqServers} | grep -F '/tailnet.fixture.test/100.100.100.100'

  touch "$out"
''
