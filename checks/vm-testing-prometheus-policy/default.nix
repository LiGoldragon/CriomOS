{
  inputs,
  pkgs,
  ...
}:

# Prometheus VM-testing node-config policy check.
#
# Asserts the per-node gpuPassthrough decision (Spirit 2632/76qdqown): the
# VM-testing feature, when enabled on the Prometheus node, resolves
# gpuPassthrough = false and the module evaluates WITHOUT arming VFIO (no
# IOMMU kernel param, no vfio-pci binding) — Prometheus is an AI node whose
# GPU must not be monopolized by passthrough.
#
# Also asserts the complementary opt-in path: a node that DOES carry
# gpuPassthrough = true arms VFIO, proving the option is real and per-node.
#
# Evaluates the vm-testing module in isolation against a synthetic horizon
# (same isolated-eval grain as checks/desktop-audio-policy), so the check
# does not need a full cluster horizon, secrets, or the whole module tree.

let
  inherit (inputs.nixpkgs) lib;

  evalVmTesting =
    horizon:
    lib.evalModules {
      modules = [
        ../../modules/nixos/vm-testing/default.nix
        # Minimal stubs for the option namespaces the module touches, so the
        # module evaluates standalone without the full NixOS module set.
        (
          { lib, ... }:
          {
            options = {
              virtualisation.libvirtd.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
              virtualisation.spiceUSBRedirection.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
              environment.systemPackages = lib.mkOption {
                type = lib.types.listOf lib.types.unspecified;
                default = [ ];
              };
              networking.hosts = lib.mkOption {
                type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                default = { };
              };
              boot.kernelParams = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              boot.kernelModules = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              boot.initrd.kernelModules = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              microvm = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                default = { };
              };
            };
          }
        )
      ];
      specialArgs = {
        inherit lib pkgs horizon;
        # Deliberately omit microvm from inputs so the standalone eval does
        # not need the microvm host module's options. haveMicrovm guards it.
        inputs = { };
      };
    };

  prometheusHorizon = {
    cluster.name = "criome";
    node = {
      name = "prometheus";
      nodeIp = "10.0.0.2/24";
      services = [
        {
          VmTesting = {
            gpuPassthrough = false;
            display = "Spice";
            gpu = null;
          };
        }
      ];
    };
  };

  # A contrasting node that opts INTO passthrough — proves the option is real.
  gpuNodeHorizon = {
    cluster.name = "criome";
    node = {
      name = "gpu-lab";
      nodeIp = "10.0.0.9/24";
      services = [
        {
          VmTesting = {
            gpuPassthrough = true;
            display = "Spice";
            gpu = "10de:1234";
          };
        }
      ];
    };
  };

  prometheus = (evalVmTesting prometheusHorizon).config;
  gpuNode = (evalVmTesting gpuNodeHorizon).config;

  hasIommuParam =
    cfg: builtins.any (param: lib.hasInfix "iommu" param) (cfg.boot.kernelParams or [ ]);
  hasVfioModule = cfg: builtins.elem "vfio_pci" (cfg.boot.kernelModules or [ ]);
in
assert lib.assertMsg prometheus.criomos.vmTesting.enable
  "Prometheus VmTesting service must enable the vm-testing feature.";
assert lib.assertMsg (
  prometheus.criomos.vmTesting.gpuPassthrough == false
) "Prometheus must resolve gpuPassthrough = false (AI node; GPU not monopolized).";
assert lib.assertMsg (
  prometheus.criomos.vmTesting.vfioArmed == false
) "Prometheus must NOT arm VFIO.";
assert lib.assertMsg (
  !hasIommuParam prometheus
) "Prometheus must carry NO IOMMU kernel param (VFIO not armed).";
assert lib.assertMsg (!hasVfioModule prometheus) "Prometheus must NOT bind vfio_pci.";
assert lib.assertMsg (
  prometheus.criomos.vmTesting.criomeDomain == "vm-testing.criome.criome"
) "Prometheus must project the Criome domain vm-testing.<cluster>.criome.";
assert lib.assertMsg (
  (prometheus.networking.hosts."10.0.0.2" or [ ]) == [ "vm-testing.criome.criome" ]
) "Prometheus must publish a hosts entry resolving the Criome domain to its node IP.";
# The opt-in path on a different node DOES arm VFIO — the option is per-node.
assert lib.assertMsg gpuNode.criomos.vmTesting.vfioArmed
  "A node with gpuPassthrough = true must report vfioArmed.";
assert lib.assertMsg (hasIommuParam gpuNode)
  "A gpuPassthrough node must carry an IOMMU kernel param.";
assert lib.assertMsg (hasVfioModule gpuNode) "A gpuPassthrough node must bind vfio_pci.";
assert lib.assertMsg (builtins.elem "vfio-pci.ids=10de:1234" gpuNode.boot.kernelParams)
  "A gpuPassthrough node must bind the declared GPU PCI id via vfio-pci.ids.";

pkgs.runCommand "vm-testing-prometheus-policy-check" { } ''
  touch "$out"
''
