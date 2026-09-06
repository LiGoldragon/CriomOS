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
    kind = "Metal";
    architecture = "x86_64";
    host = null;
    additionalHosts = [ ];
    user = null;
    diskGib = 20;
    hardware = {
      cores = 2;
      model = "all-x86-64";
      motherboard = null;
      chipGeneration = null;
      ramGib = 4;
      location = null;
    };
  };

  baseNode = name: {
    inherit name;
    cacheUrls = [ ];
    capabilities = [ ];
    behavesAs = {
      testVm = false;
    };
    machine = baseMachine;
  };

  virtualMachineHostCapability = {
    kind = "vmHost";
    guest_subnet = "169.254.100.0/22";
    kvm = "Available";
    maximum_guests = 4;
  };

  atlas = (baseNode "atlas") // {
    nixPublicKeyLine = atlasKey;
    capabilities = [ virtualMachineHostCapability ];
  };

  prometheus = (baseNode "prometheus") // {
    nixPublicKeyLine = prometheusKey;
    capabilities = [ virtualMachineHostCapability ];
  };

  apollo = (baseNode "apollo") // {
    nixPublicKeyLine = apolloKey;
  };

  mercury = (baseNode "mercury") // {
    nodeIp = "10.77.0.7/24";
    criomeDomainName = "mercury.fieldlab.criome";
    behavesAs = {
      testVm = true;
    };
    network = {
      nodeIp = "10.77.0.7/24";
    };
    machine = baseMachine // {
      kind = "VirtualMachine";
      host = "atlas";
      additionalHosts = [ "prometheus" ];
    };
  };

  singleHostMercury = mercury // {
    machine = mercury.machine // {
      additionalHosts = [ ];
    };
  };

  horizonFor = node: exNodes: {
    cluster = "fieldlab";
    trustedBuildPublicKeys = clusterKeys;
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
