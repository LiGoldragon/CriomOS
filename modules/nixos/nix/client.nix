{
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib) filterAttrs mapAttrsToList;

  inherit (horizon.cluster) trustedBuildPubKeys;
  inherit (horizon) node;
  inherit (horizon.node) cacheUrls;

  # Build a flake-registry entry from a locked input's `sourceInfo`.
  # Same lock input -> same registry entry on deployed nodes.
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

  nixFlakeRegistryJson = pkgs.writeText "criomos-flake-registry.json" (
    builtins.toJSON nixFlakeRegistry
  );
in
{
  users.groups.nixdev = { };

  nix = {
    package = pkgs.nixVersions.latest;

    channel.enable = false;

    settings = {
      trusted-users = [
        "root"
        "@nixdev"
      ];

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
    };

    extraOptions = ''
      flake-registry = ${nixFlakeRegistryJson}
      experimental-features = nix-command flakes recursive-nix

      # !include <path>: include without an error for missing file.
      !include nixTokens
    '';
  };
}
