# The deployed flake registry names every registered input by its full
# locked source identity. The oracle is this flake's own flake.lock, read
# with jq, independently of the Nix code that builds the registry; and
# `nix registry list` must parse the registry without an attribute warning.
{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  configuration =
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          trustedBuildPublicKeys = [ ];
          node = {
            behavesAs.center = false;
            buildCores = 2;
            builderConfigs = [ ];
            cacheUrls = [ ];
            dispatchersSshPublicKeys = [ ];
            isDispatcher = false;
            isNixCache = false;
            isRemoteNixBuilder = false;
            size = "Min";
          };
        };
      };
      modules = [
        ../../modules/nixos/nix/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  # builtins.match drops string context; restore it from extraOptions so the
  # registry file is an input of the check derivation.
  registryPath = builtins.appendContext (builtins.head (
    builtins.match ".*flake-registry = ([^\n]*)\n.*" configuration.nix.extraOptions
  )) (builtins.getContext configuration.nix.extraOptions);
  registeredIds = [
    "brightness-ctl"
    "criomos-home"
    "home-manager"
    "nixpkgs"
  ];
in
pkgs.runCommand "flake-registry-shape"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.nixVersions.latest
    ];
    registry = registryPath;
    lock = ../../flake.lock;
  }
  ''
    set -eu
    test "$(jq -c '[.flakes[].from.id] | sort' "$registry")" = ${lib.escapeShellArg (builtins.toJSON registeredIds)}
    for id in ${lib.escapeShellArgs registeredIds}; do
      node=$(jq -r --arg id "$id" '.nodes[.root].inputs[$id]' "$lock")
      expected=$(jq -c --arg n "$node" '.nodes[$n].locked | {type, owner, repo}' "$lock")
      actual=$(jq -c --arg id "$id" '.flakes[] | select(.from.id == $id) | .to | {type, owner, repo}' "$registry")
      echo "$id: expected $expected actual $actual"
      test "$expected" = "$actual"
      jq -e --arg id "$id" '.flakes[] | select(.from.id == $id) | .to.rev | test("^[0-9a-f]{40}$")' "$registry" > /dev/null
    done

    export HOME="$TMPDIR" NIX_STATE_DIR="$TMPDIR/state" NIX_CONFIG="experimental-features = nix-command flakes"
    nix --store dummy:// --option flake-registry "$registry" registry list > listing 2> warnings
    cat listing warnings
    # The sandbox has no network; that notice is expected. Any other stderr
    # line (such as "input attribute 'owner' is missing") fails the check.
    grep -v "you don't have Internet access" warnings > unexpected || true
    test ! -s unexpected
    test "$(grep -c '^global flake:' listing)" = ${toString (builtins.length registeredIds)}
    grep -E '^global flake:criomos-home github:LiGoldragon/CriomOS-home/[0-9a-f]{40}$' listing
    cp listing "$out"
  ''
