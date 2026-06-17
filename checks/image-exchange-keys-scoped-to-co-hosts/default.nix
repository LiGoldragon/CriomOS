{
  inputs,
  pkgs,
  ...
}:

# Image-exchange trust policy check.
#
# Unit 3 of the VM-testing handoff: a VM host emits additive
# nix.settings.extra-trusted-public-keys for exactly the peer hosts that share
# a TestVm guest with it. The normal cluster-wide trusted-public-keys pool stays
# owned by the Nix client module and must not be replaced by this scoped trust
# set.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  atlasKey = "atlas.example:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  prometheusKey = "prometheus.example:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
  apolloKey = "apollo.example:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=";
  clusterKeys = [
    atlasKey
    prometheusKey
    apolloKey
  ];

  baseMachine = {
    arch = "X86_64Linux";
    cores = 2;
    ramGb = 4;
    diskGb = 20;
    location = null;
    superNode = null;
    superNodes = [ ];
  };

  baseNode = name: {
    inherit name;
    cacheUrls = [ ];
    services = [ ];
    behavesAs = { };
    machine = baseMachine;
  };

  virtualMachineHostService = {
    VmHost = {
      guestSubnet = "169.254.100.0/22";
      kvm = "Available";
      maximumGuests = 4;
    };
  };

  atlas = (baseNode "atlas") // {
    nixPubKeyLine = atlasKey;
    services = [ virtualMachineHostService ];
  };

  prometheus = (baseNode "prometheus") // {
    nixPubKeyLine = prometheusKey;
    services = [ virtualMachineHostService ];
  };

  apollo = (baseNode "apollo") // {
    nixPubKeyLine = apolloKey;
  };

  mercury = (baseNode "mercury") // {
    nodeIp = "10.77.0.7/24";
    criomeDomainName = "mercury.fieldlab.criome";
    behavesAs.testVm = true;
    machine = baseMachine // {
      superNode = "atlas";
      superNodes = [ "prometheus" ];
    };
  };

  singleHostMercury = mercury // {
    machine = baseMachine // {
      superNode = "atlas";
      superNodes = [ ];
    };
  };

  horizonFor = node: exNodes: {
    cluster = {
      name = "fieldlab";
      trustedBuildPubKeys = clusterKeys;
    };
    inherit node exNodes;
  };

  configurationFor =
    horizon:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs horizon;
      };
      modules = [
        ../../modules/nixos/nix/client.nix
        ../../modules/nixos/test-vm-host.nix
        (
          { lib, ... }:
          {
            options.microvm.vms = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = { };
            };
            config.system.stateVersion = "26.05";
          }
        )
      ];
    };

  atlasMultiHostConfiguration =
    (configurationFor (
      horizonFor atlas {
        inherit prometheus apollo mercury;
      }
    )).config;

  prometheusAdditionalHostConfiguration =
    (configurationFor (
      horizonFor prometheus {
        inherit atlas apollo mercury;
      }
    )).config;

  atlasSingleHostConfiguration =
    (configurationFor (
      horizonFor atlas {
        inherit prometheus apollo;
        mercury = singleHostMercury;
      }
    )).config;

  extraTrustedPublicKeysOf =
    configuration: configuration.nix.settings.extra-trusted-public-keys or [ ];
  trustedPublicKeysOf = configuration: configuration.nix.settings.trusted-public-keys or [ ];

  bool = value: if value then "true" else "false";
in
pkgs.runCommand "image-exchange-keys-scoped-to-co-hosts" { } ''
  set -eu

  # Primary host: the additional co-host key lands.
  test ${lib.escapeShellArg (bool (builtins.elem prometheusKey (extraTrustedPublicKeysOf atlasMultiHostConfiguration)))} = true

  # Primary host: keyed non-co-hosts remain outside the scoped image-exchange set.
  test ${
    lib.escapeShellArg (
      bool (!(builtins.elem apolloKey (extraTrustedPublicKeysOf atlasMultiHostConfiguration)))
    )
  } = true

  # Primary host: its own key is not redundantly trusted as an exchange peer.
  test ${
    lib.escapeShellArg (
      bool (!(builtins.elem atlasKey (extraTrustedPublicKeysOf atlasMultiHostConfiguration)))
    )
  } = true

  # Additional host: the relation is symmetric for the declared host-set even
  # though this host does not emit microvm.vms for the guest.
  test ${lib.escapeShellArg (bool (builtins.elem atlasKey (extraTrustedPublicKeysOf prometheusAdditionalHostConfiguration)))} = true
  test ${
    lib.escapeShellArg (
      bool (!(builtins.elem apolloKey (extraTrustedPublicKeysOf prometheusAdditionalHostConfiguration)))
    )
  } = true

  # The scoped trust set is additive; the cluster-wide pool remains intact.
  test ${
    lib.escapeShellArg (
      bool (
        builtins.all (key: builtins.elem key (trustedPublicKeysOf atlasMultiHostConfiguration)) clusterKeys
      )
    )
  } = true
  test ${
    lib.escapeShellArg (
      bool (
        builtins.all (
          key: builtins.elem key (trustedPublicKeysOf prometheusAdditionalHostConfiguration)
        ) clusterKeys
      )
    )
  } = true

  # Single-host TestVm guests do not add exchange trust peers.
  test ${lib.escapeShellArg (builtins.toJSON (extraTrustedPublicKeysOf atlasSingleHostConfiguration))} = '[]'

  touch "$out"
''
