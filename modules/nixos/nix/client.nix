{
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib) filterAttrs mapAttrsToList;

  trustedBuildPubKeys = horizon.trustedBuildPublicKeys;
  inherit (horizon) node;
  inherit (horizon.node) cacheUrls;

  dedicatedNixBuilder = (node.isRemoteNixBuilder or false) && (node.behavesAs.center or false);
  localBuildCores = if dedicatedNixBuilder then (node.buildCores or 2) else 2;
  # A node that is not any kind of Nix builder (goldragon, and every other
  # ordinary client) has no legitimate reason to run a build slot of its own:
  # `max-jobs = 0` makes local building impossible for every user on it,
  # root included, matching the living's ruling that Prometheus is the only
  # place a build ever runs. A node that IS a remote builder — dedicated
  # (`dedicatedNixBuilder`, handled above) or an edge builder that still
  # serves `sshServe` builds for a dispatcher without being the cluster
  # center — keeps its prior single local slot so it can still service the
  # builds routed to it; only a node with no builder role at all drops to 0.
  localMaxJobs =
    if dedicatedNixBuilder then
      (node.maxJobs or 4)
    else if (node.isRemoteNixBuilder or false) then
      1
    else
      0;

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

      cores = localBuildCores;
      max-jobs = localMaxJobs;

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
