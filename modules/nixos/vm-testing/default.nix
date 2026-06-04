{
  lib,
  horizon,
  pkgs,
  config,
  inputs,
  ...
}:

# CriomOS VM-testing node feature.
#
# Intent: Spirit 2630 (VM-based testing node using the best Linux VM
# technology — QEMU/KVM — to test CriomOS and its components, including the
# visual/GPU cases such as chroma's gamma warmth that a headless sandbox
# cannot exercise), Spirit 2631 (reachable via a Criome domain such as
# vm-testing.<cluster>.criome through domain-criome plus cluster networking),
# and Spirit 2632/76qdqown (the per-node gpuPassthrough option — VFIO GPU
# passthrough for the gamma visual test — DISABLED on Prometheus, because
# Prometheus is an AI node whose GPU must not be monopolized by vfio-pci).
#
# Design report: reports/system-designer/67-criomos-vm-testing-node-feature-
# concept-2026-06-04.md.
#
# Shape: a horizon node-service variant `VmTesting` (resolved by
# node-services.nix exactly like `TailnetClient`) with payload fields
#   - gpuPassthrough : bool  (default false — opt-in per node; VFIO is
#                             armed ONLY when true)
#   - display        : the remote-display protocol (default Spice)
#   - gpu            : PCI id of the GPU to pass through (null = virtio-gpu
#                             default mode, no passthrough)
# This module installs the QEMU + microvm.nix harness, defines the persistent
# routed test microVM with a remote display, registers the Criome domain
# vm-testing.<cluster>.criome, and arms VFIO only when gpuPassthrough = true.

let
  inherit (lib)
    mkIf
    mkMerge
    mkDefault
    optionals
    optionalAttrs
    ;
  inherit (horizon) node;
  cluster = horizon.cluster or { };

  nodeServices = import ../node-services.nix { inherit lib; };

  enabled = nodeServices.has (node.services or [ ]) "VmTesting";
  payload = nodeServices.payload (node.services or [ ]) "VmTesting";

  # Payload defaults. Per the design these are chosen-and-adjustable:
  #   display = Spice (best interactive latency + clipboard),
  #   gpuPassthrough = false (opt-in; never armed implicitly),
  #   gpu = null (virtio-gpu default mode).
  gpuPassthrough = payload.gpuPassthrough or false;
  display = payload.display or "Spice";
  gpu = payload.gpu or null;
  displayLower = lib.toLower display;

  # Criome domain for the persistent routed test VM. Rendered from cluster
  # facts (Horizon-derived data), never a Nix control-flow predicate, per
  # CriomOS's network-neutrality rule. `cluster.name` flows from Horizon.
  clusterName = cluster.name or node.name;
  criomeDomain = "vm-testing.${clusterName}.criome";

  # The reachable address the domain resolves to: the host's own node IP
  # (CriomOS nodes are in the tailnet; the .criome authority delegates the
  # name to this node). Strip any CIDR suffix.
  inherit (builtins) head split;
  rawNodeIp = node.nodeIp or null;
  nodeAddress = if rawNodeIp == null then null else head (split "/" rawNodeIp);

  # microvm.nix is available as a flake input when wired (it is, on the
  # CriomOS flake). Guard so eval does not throw if a downstream consumer
  # ever drops the input.
  haveMicrovm = inputs ? microvm;
in
{
  options.criomos.vmTesting = {
    enable = lib.mkEnableOption "the CriomOS VM-testing node feature";
    display = lib.mkOption {
      type = lib.types.str;
      default = "Spice";
      description = "Remote-display protocol for the persistent test VM (Spice default).";
    };
    gpuPassthrough = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Arm VFIO GPU passthrough for the gamma visual test. Opt-in per node; DISABLED on Prometheus.";
    };
    gpu = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "PCI vendor:device id of the GPU to pass through when gpuPassthrough is true. null = virtio-gpu mode.";
    };
    criomeDomain = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Projected Criome domain for the persistent test VM (vm-testing.<cluster>.criome).";
    };
    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Reachable address the Criome domain resolves to (the host's node IP).";
    };
    vfioArmed = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether VFIO passthrough was armed (true iff gpuPassthrough). Surfaced for checks.";
    };
  };

  config = mkIf enabled (mkMerge [
    {
      # QEMU/KVM runtime + the persistent-VM substrate. microvm.nix is wired
      # via the flake input (imported in criomos.nix); here we ensure the host
      # can run hardware-accelerated guests and exposes the harness tooling.
      virtualisation.libvirtd.enable = mkDefault true;
      virtualisation.spiceUSBRedirection.enable = displayLower == "spice";

      environment.systemPackages =
        with pkgs;
        [
          qemu_kvm
          OVMF.fd
        ]
        ++ optionals (displayLower == "spice") [
          spice
          spice-gtk
        ];

      # Provider-neutral Criome-domain projection. The persistent test VM's
      # remote-display + harness endpoint is published as
      # vm-testing.<cluster>.criome. domain-criome owns registration/
      # resolution; here CriomOS emits the host-side hosts entry that resolves
      # the name to the VM-testing host's reachable address, matching
      # network/default.nix's mkCriomeHostEntries grain. The structured
      # projection is surfaced under config.criomos.vmTesting for the
      # domain-criome registration path and for checks to consume.
      networking.hosts = optionalAttrs (nodeAddress != null) {
        "${nodeAddress}" = [ criomeDomain ];
      };

      criomos.vmTesting = {
        enable = true;
        inherit
          display
          gpuPassthrough
          gpu
          criomeDomain
          ;
        address = nodeAddress;
        vfioArmed = gpuPassthrough;
      };

      # Persistent routed test microVM with a remote display, declared via
      # microvm.nix when the input is present. A virtio-gpu guest (default
      # mode) reachable over the Criome domain. The guest config is kept
      # minimal here — the desktop/component test surface is exercised by the
      # ephemeral runNixOSTest checks; this persistent VM is the long-lived,
      # human-viewable endpoint (Spirit 2630's "interactively viewable" half).
      microvm = lib.mkIf haveMicrovm {
        vms.vm-testing = {
          config = {
            microvm = {
              hypervisor = "qemu";
              vcpu = 2;
              mem = 2048;
              graphics.enable = true;
              interfaces = [
                {
                  type = "tap";
                  id = "vm-testing";
                  mac = "02:00:00:00:00:01";
                }
              ];
            };
            networking.hostName = "vm-testing";
            system.stateVersion = lib.trivial.release;
          };
        };
      };
    }

    # VFIO GPU passthrough — armed ONLY when gpuPassthrough = true (opt-in per
    # node). Driven entirely by Horizon payload data, never a hardcoded node
    # name, per CriomOS's network-neutral rule. On Prometheus the payload
    # carries gpuPassthrough = false, so this whole branch is inert and no
    # vfio-pci binding, IOMMU param, or GPU release happens.
    (mkIf gpuPassthrough {
      boot.kernelParams = [
        "intel_iommu=on"
        "amd_iommu=on"
        "iommu=pt"
      ]
      ++ optionals (gpu != null) [
        "vfio-pci.ids=${gpu}"
      ];
      boot.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
      ];
      boot.initrd.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
      ];
    })
  ]);
}
