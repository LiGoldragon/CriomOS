{
  inputs,
  pkgs,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  horizonNode = import ../../fixtures/horizon-node.nix { inherit lib; };

  node =
    fixedLocation:
    horizonNode.node {
      inherit fixedLocation;
      behavesAs.edge = true;
      machine.hardware.model = "all-x86-64";
    };

  configurationFor =
    fixedLocation:
    (lib.nixosSystem {
      inherit pkgs;
      specialArgs = {
        inherit inputs;
        horizon.node = node fixedLocation;
      };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  dynamic = configurationFor null;
  static = configurationFor {
    latitude = 16.736944;
    longitude = -92.6375;
    altitude = 2121.0;
    accuracy = 1000.0;
  };
in
assert lib.assertMsg (
  !dynamic.services.geoclue2.enableStatic
) "nodes without fixedLocation must keep dynamic GeoClue sources";
assert lib.assertMsg static.services.geoclue2.enableStatic
  "fixedLocation must enable GeoClue's static source";
assert lib.assertMsg (
  static.services.geoclue2.staticLatitude == 16.736944
) "fixedLocation latitude must reach GeoClue";
assert lib.assertMsg (
  static.services.geoclue2.staticLongitude == -92.6375
) "fixedLocation longitude must reach GeoClue";
assert lib.assertMsg (
  static.services.geoclue2.staticAltitude == 2121.0
) "fixedLocation altitude must reach GeoClue";
assert lib.assertMsg (
  static.services.geoclue2.staticAccuracy == 1000.0
) "fixedLocation accuracy must reach GeoClue";
pkgs.runCommand "fixed-location-policy" { } ''
  touch "$out"
''
