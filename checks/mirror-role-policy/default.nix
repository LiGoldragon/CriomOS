{ inputs, pkgs, ... }:

# mirror.service is force-disabled on ALL hosts (primary-h945.1). The legacy
# standalone mirror-0.1.2 daemon crash-loops on a redb HeadFamily table
# type-signature mismatch, which makes `switch-to-configuration switch` exit 4
# and blocks System deploys (agent-outputs/LojixDeployAuthMap/
# Scout-H945-NoPermissionDiagnosis.md). This policy check pins the disabled
# posture — the unit is absent even on the previously mirror-eligible node
# shape (TailnetClient + PersonaDevelopment, i.e. ouranos) — while proving the
# module + `mirror` flake input stay wired so re-enabling is reversible.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseNode = {
    services = [ ];
  };

  personaOnlyNode = {
    services = [
      {
        PersonaDevelopment = {
          capabilities = [
            { GitoliteServer = { }; }
          ];
        };
      }
    ];
  };

  # The previously mirror-eligible shape: a cluster tailnet member that also
  # carries PersonaDevelopment (ouranos). Before the disable, mirror.service ran
  # here; it must now be absent too.
  mirrorEligibleNode = {
    services = [
      { TailnetClient = { }; }
      {
        PersonaDevelopment = {
          capabilities = [
            { GitoliteServer = { }; }
          ];
        };
      }
    ];
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/mirror.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  baseConfiguration = configurationFor baseNode;
  personaOnlyConfiguration = configurationFor personaOnlyNode;
  mirrorEligibleConfiguration = configurationFor mirrorEligibleNode;

  servicePresent = configuration: builtins.hasAttr "mirror" configuration.config.systemd.services;

  # Reversibility witness: the mirror flake input stays wired to a buildable
  # package, so re-enabling the service is a one-line change to the module gate.
  mirrorPackage = inputs.mirror.packages.${system}.default;
  mirrorPackageName = mirrorPackage.pname or mirrorPackage.name or "unnamed";
in
pkgs.runCommand "mirror-role-policy" { } ''
  set -eu

  # Disabled on ALL hosts: absent on the empty, persona-only, AND the
  # previously mirror-eligible (ouranos-shaped) node.
  test ${lib.escapeShellArg (bool (servicePresent baseConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent personaOnlyConfiguration))} = false
  test ${lib.escapeShellArg (bool (servicePresent mirrorEligibleConfiguration))} = false

  # Wiring preserved (reversible): the `mirror` flake input still resolves to
  # the mirror package.
  printf '%s' ${lib.escapeShellArg mirrorPackageName} | grep -F mirror

  touch "$out"
''
