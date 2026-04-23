{ inputs }:

# crioZones.<cluster>.<node>.{ os, fullOs, vm, home.<user>, deployManifest }
#
# This is CriomOS's non-standard output. It does NOT enumerate hosts.
# A "cluster" is any flake input whose outputs expose a `NodeProposal` attr.
# CriomOS is network-neutral: the clusters it serves are entirely
# determined by which inputs the consumer (or CI) has declared.
#
# Shape (once wired):
#   crioZones = mapAttrs mkClusterZones (discoverClusters inputs);
#   discoverClusters = filterAttrs (_: v: v ? NodeProposal) inputs;
#   mkClusterZones   = clusterName: clusterInput:
#     mapAttrs (mkNode clusterName clusterInput) clusterInput.NodeProposal.nodes;
#   mkNode = clusterName: clusterInput: nodeName: _:
#     let horizon = lib.mkHorizon { inherit inputs clusterName nodeName; };
#     in {
#       os             = …evalNixos… ;
#       fullOs         = …with users… ;
#       vm             = …qemu VM… ;
#       home.<user>    = …home-manager per user… ;
#       deployManifest = …JSON manifest… ;
#     };
#
# Empty during Phase 0 scaffold.

{ }
