{
  lib,
  criomos-lib,
  pkdjz,
  pkgs,
  hob,
  horizon,
  world,
  constants,
  ...
}:
with builtins;
let
  inherit (lib)
    boolToString
    mapAttrsToList
    optionals
    optional
    optionalAttrs
    ;

  inherit (pkdjz) exportJSON;

  inherit (horizon.cluster.methods) trustedBuildPreCriomes;
  inherit (horizon) node;
  inherit (horizon.node.methods)
    cacheURLs
    dispatchersSshPreCriomes
    exNodesSshPreCriomes
    sizedAtLeast
    isBuilder
    isNixCache
    hasNixPreCriad
    ;

  inherit (constants.fileSystem.nix) preCriad;
  inherit (constants.network.nix) serve;

  optionalNixpkgsRef = optionalAttrs (hob.nixpkgs ? ref) { inherit (hob.nixpkgs) ref; };

  flakeEntriesOverrides = {
    lib = {
      owner = "nix-community";
      repo = "nixpkgs.lib";
    };

    nixpkgs = {
      owner = "criome";
      repo = "nixpkgs";
      inherit (hob.nixpkgs) rev;
    }
    // optionalNixpkgsRef;

    nixpkgs-master = {
      owner = "NixOS";
      repo = "nixpkgs";
    };

  };

  mkFlakeEntriesListFromSet =
    entriesMap:
    let
      mkFlakeEntry = name: value: {
        from = {
          id = name;
          type = "indirect";
        };
        to = {
          repo = name;
          type = "github";
        } // value;
      };
    in
    mapAttrsToList mkFlakeEntry entriesMap;

  criomOSFlakeEntries = mkFlakeEntriesListFromSet flakeEntriesOverrides;

  nixOSFlakeEntries =
    let
      nixOSFlakeRegistry = criomos-lib.importJSON world.pkdjz.flake-registry;
    in
    nixOSFlakeRegistry.flakes;

  filterOutRegistry =
    entry:
    let
      flakeName = entry.from.id;
      flakeOverrideNames = attrNames flakeEntriesOverrides;
      entryIsOverridden = elem flakeName flakeOverrideNames;
    in
    !entryIsOverridden;

  filteredNixosFlakeEntries = filter filterOutRegistry nixOSFlakeEntries;

  nixFlakeRegistry = {
    flakes = criomOSFlakeEntries ++ filteredNixosFlakeEntries;
    version = 2;
  };

  nixFlakeRegistryJson = exportJSON "nixFlakeRegistry.json" nixFlakeRegistry;

in
{
  networking = {
    firewall = {
      allowedTCPPorts =
        optionals isNixCache [
          serve.ports.external
          80
        ]
        ++ optional (node.name == "prometheus") 11436;
    };
  };

  nix = {
    package = pkgs.nixVersions.latest;

    channel.enable = false;

    settings = {
      trusted-users = [
        "root"
        "@nixdev"
      ]
      ++ optional isBuilder "nixBuilder";

      allowed-users = [
        "@users"
        "nix-serve"
      ];

      build-cores = node.nbOfBuildCores;

      connect-timeout = 5;
      fallback = true;

      trusted-public-keys = trustedBuildPreCriomes;
      substituters = cacheURLs;
      trusted-binary-caches = cacheURLs;

      auto-optimise-store = true;
    };

    sshServe.enable = true;
    sshServe.keys = exNodesSshPreCriomes;

    # Lowest priorities
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedPriority = 7;

    extraOptions = ''
      flake-registry = ${nixFlakeRegistryJson}
      experimental-features = nix-command flakes recursive-nix
      keep-derivations = ${boolToString sizedAtLeast.med}
      keep-outputs = ${boolToString sizedAtLeast.max}

      # !include <path>:  include without an error for missing file. 
      !include nixTokens
    '';

    # TODO - broken
    # distributedBuilds = isDispatcher;
    # buildMachines = optionals isDispatcher builderConfigs;

  };

  users = {
    groups = {
      nixdev = { };
    }
    // (optionalAttrs isBuilder { nixBuilder = { }; })
    // (optionalAttrs isNixCache {
      nix-serve = {
        gid = 199;
      };
    });

    users =
      (optionalAttrs isNixCache {
        nix-serve = {
          uid = 199;
          group = "nix-serve";
        };
      })
      // (optionalAttrs isBuilder {
        nixBuilder = {
          isNormalUser = true;
          useDefaultShell = true;
          openssh.authorizedKeys.keys = dispatchersSshPreCriomes;
        };
      });
  };
}
