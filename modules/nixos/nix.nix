{
  lib,
  pkgs,
  horizon,
  inputs,
  constants,
  ...
}:
let
  inherit (lib)
    boolToString
    mapAttrsToList
    optionals
    optional
    optionalAttrs
    filterAttrs
    ;

  inherit (horizon.cluster) trustedBuildPubKeys;
  inherit (horizon) node;
  inherit (horizon.node)
    cacheUrls
    dispatchersSshPubKeys
    exNodesSshPubKeys
    size
    isBuilder
    isNixCache
    ;

  inherit (constants.network.nix) serve;

  # Build a flake-registry entry from a locked input's `sourceInfo`.
  # The `inputs.<name>` value gets `sourceInfo.{type,owner,repo,rev}`
  # populated when the input is locked (i.e. for any github:/git+/...
  # input present in flake.lock). Same nixpkgs pin → same entry.
  mkFlakeEntry = name: input: {
    from = {
      id = name;
      type = "indirect";
    };
    to = filterAttrs (_: v: v != null && v != "") {
      type = input.sourceInfo.type or "github";
      owner = input.sourceInfo.owner or null;
      repo = input.sourceInfo.repo or null;
      rev = input.sourceInfo.rev or null;
    };
  };

  # The set of inputs we expose as flake-registry pins on deployed
  # nodes. Roughly: things a user would `nix run`/`nix develop`
  # against on the node and want to share the rev CriomOS was built
  # with.
  registered = {
    inherit (inputs)
      nixpkgs
      home-manager
      brightness-ctl
      criomos-home
      ;
  };

  nixFlakeRegistry = {
    flakes = mapAttrsToList mkFlakeEntry registered;
    version = 2;
  };

  nixFlakeRegistryJson = pkgs.writeText "criomos-flake-registry.json"
    (builtins.toJSON nixFlakeRegistry);

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

      build-cores = node.buildCores;

      connect-timeout = 5;
      fallback = true;

      trusted-public-keys = trustedBuildPubKeys;
      substituters = cacheUrls;
      trusted-binary-caches = cacheUrls;

      auto-optimise-store = true;
    };

    sshServe.enable = true;
    sshServe.keys = exNodesSshPubKeys;

    # Lowest priorities
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedPriority = 7;

    extraOptions = ''
      flake-registry = ${nixFlakeRegistryJson}
      experimental-features = nix-command flakes recursive-nix
      keep-derivations = ${boolToString size.atLeastMed}
      keep-outputs = ${boolToString size.atLeastLarge}

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
          openssh.authorizedKeys.keys = dispatchersSshPubKeys;
        };
      });
  };
}
