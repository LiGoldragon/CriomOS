{
  lib,
  criomos-lib,
  proposedCrioSphere,
}:
let
  inherit (builtins) mapAttrs;
  inherit (lib) evalModules;

  clusters = proposedCrioSphere;

  horizonOptions = import ./horizonOptions.nix;
  mkHorizonModule = import ./mkHorizonModule.nix;

  mkCrioZone =
    clusterName: nodeName:
    let
      argumentsModule = {
        config = {
          inherit nodeName clusterName;
          _module.args = {
            inherit lib criomos-lib;
            Clusters = clusters.datom;
            clustersSpecies = clusters.species;
          };
        };
      };

      evaluation = evalModules {
        modules = [
          argumentsModule
          horizonOptions
          mkHorizonModule
        ];
      };

      crioZone = evaluation.config.horizon;

    in
    crioZone;

  mkNodeCrioZones = nodeName: node: mapAttrs (pnn: pn: mkCrioZone nodeName pnn) node.nodes;

  ryzylt = mapAttrs mkNodeCrioZones proposedCrioSphere.datom;

in
ryzylt
