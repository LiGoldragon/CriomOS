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
  # Compilation is served only by the projected center builder. Client and
  # edge roles have no local fallback slot.
  localMaxJobs = if dedicatedNixBuilder then (node.maxJobs or 4) else 0;

  # A locked github input's `sourceInfo` carries only outPath, rev, narHash
  # and lastModified, so the source identity (type, owner, repo) is read
  # from this flake's own lock node for the input. The revision stays read
  # from `sourceInfo`, so a deploy-time `--override-input` still registers
  # the revision that was actually built.
  flakeLock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  lockedInput = name: flakeLock.nodes.${flakeLock.nodes.${flakeLock.root}.inputs.${name}}.locked;

  # Same lock input -> same registry entry on deployed nodes.
  mkFlakeEntry = name: input: {
    from = {
      id = name;
      type = "indirect";
    };
    to = filterAttrs (_: v: v != null && v != "") {
      inherit (lockedInput name) type owner repo;
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
