{ inputs, pkgs, ... }:
let
  lib = inputs.nixpkgs.lib;
  service = {
    usbIpv4Gateway = {
      downstream = "enp0s20f0u1c2";
      downstreamMac = "00:0e:c6:33:4f:97";
      gateway = "10.44.0.1/24";
      uplink = "enp0s31f6";
    };
  };
  uuid = "92eb01d2-2087-44c9-a6ff-b2420df89d33";
  fixture =
    capabilities: options:
    lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs.horizon.node.capabilities = capabilities;
      modules = [
        ../../modules/nixos/network/usb-ipv4-gateway.nix
        (
          { ... }:
          {
            networking.networkmanager.enable = true;
            criomos.usbIpv4Gateway.profileUuid = uuid;
          }
          // options
        )
      ];
    };
  active = (fixture [ service ] { }).config;
  flattened = (fixture [ (service.usbIpv4Gateway // { kind = "usbIpv4Gateway"; }) ] { }).config;
  absent = (fixture [ { kind = "tailnetClient"; } ] { }).config;
  rejects =
    capabilities:
    !(builtins.tryEval (
      builtins.deepSeq (fixture capabilities { }).config.networking.networkmanager.ensureProfiles.profiles
        true
    )).success;
  missingUuid =
    !(builtins.tryEval (
      builtins.deepSeq
        (fixture [ service ] { criomos.usbIpv4Gateway.profileUuid = null; })
        .config.networking.networkmanager.ensureProfiles.profiles
        true
    )).success;
  hasFailedAssertion =
    options: builtins.any (item: !item.assertion) (fixture [ service ] options).config.assertions;
  profile = active.networking.networkmanager.ensureProfiles.profiles."usb-ipv4-gateway";
  rules = active.networking.firewall.extraCommands;
  valid =
    profile.connection.uuid == uuid
    && profile.connection."interface-name" == service.usbIpv4Gateway.downstream
    && profile.ethernet."mac-address" == service.usbIpv4Gateway.downstreamMac
    && profile.ipv4.method == "shared"
    && profile.ipv4.address1 == service.usbIpv4Gateway.gateway
    && profile.ipv4."never-default" == "true"
    && profile.ipv6.method == "link-local"
    && profile.ipv6."never-default" == "true"
    && profile.ipv6."ignore-auto-dns" == "true"
    && active.networking.networkmanager.settings.main."firewall-backend" == "none"
    && lib.hasInfix "-o enp0s31f6" rules
    && lib.hasInfix "-i enp0s20f0u1c2" rules
    && flattened.networking.networkmanager.ensureProfiles.profiles."usb-ipv4-gateway" == profile
    && absent.networking.networkmanager.ensureProfiles.profiles == { }
    && (absent.networking.networkmanager.settings.main."firewall-backend" or null) == null
    && missingUuid
    && rejects [
      service
      service
    ]
    && rejects [
      {
        usbIpv4Gateway = service.usbIpv4Gateway // {
          uplink = "enp0s20f0u1c2";
        };
      }
    ]
    && rejects [
      {
        usbIpv4Gateway = service.usbIpv4Gateway // {
          downstreamMac = "01:0e:c6:33:4f:97";
        };
      }
    ]
    && rejects [
      {
        usbIpv4Gateway = service.usbIpv4Gateway // {
          gateway = "10.44.0.1/33";
        };
      }
    ]
    && hasFailedAssertion { networking.networkmanager.enable = false; }
    && hasFailedAssertion { networking.useNetworkd = true; }
    && hasFailedAssertion {
      networking.networkmanager.ensureProfiles.profiles.foreign = {
        connection = {
          id = "foreign";
          type = "ethernet";
        };
        ipv4.method = "shared";
      };
    }
    && hasFailedAssertion { networking.nat.enable = true; };
in
assert valid;
pkgs.runCommand "usb-ipv4-gateway-policy" { } ''
  touch "$out"
''
