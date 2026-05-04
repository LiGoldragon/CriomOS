{
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib)
    boolToString
    listToAttrs
    mapAttrsToList
    mkIf
    optionals
    optional
    optionalAttrs
    filterAttrs
    ;

  inherit (horizon.cluster) trustedBuildPubKeys;
  inherit (horizon) node;
  inherit (horizon.node)
    builderConfigs
    cacheUrls
    dispatchersSshPubKeys
    size
    isBuilder
    isDispatcher
    isNixCache
    ;

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

  nixFlakeRegistryJson = pkgs.writeText "criomos-flake-registry.json" (
    builtins.toJSON nixFlakeRegistry
  );

in
{
  networking = {
    firewall = {
      allowedTCPPorts =
        optionals isNixCache [
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

      auto-optimise-store = true;

      # When this node dispatches a derivation to a remote builder,
      # the builder fetches the dep closure from cache.nixos.org
      # itself rather than streaming through the dispatcher. Almost
      # always correct — only turn off if the builder lacks egress.
      builders-use-substitutes = isDispatcher;
    };

    # ─── Build receiver (this node serves builds via SSH) ──────
    #
    # Gated on `isBuilder` so only nodes flagged as build targets
    # in horizon expose the service. `nix.sshServe.enable = true`
    # creates a restricted `nix-ssh` user whose only allowed
    # command is `nix-daemon --stdio` (ssh-ng) — no shell, no PTY.
    # `write = true` lets clients upload .drv inputs (required for
    # build dispatch, not just substitution). `trusted = true`
    # adds nix-ssh to trusted-users so the daemon will actually
    # *build* on its behalf instead of refusing with privilege
    # errors (the most common breakage when this is omitted).
    #
    # `keys` carries the **dispatcher** nodes' SSH host pubkeys
    # (sourced from `horizon.node.dispatchersSshPubKeys` — the
    # ex-nodes that horizon-rs flagged as `isDispatcher`). The
    # convention used: each NixOS host's `/etc/ssh/ssh_host_ed25519_key`
    # serves as the daemon's SSH client identity, and the
    # corresponding pubkey is what the builder authorizes. Avoids
    # provisioning `/root/.ssh/id_*` declaratively (NixOS doesn't
    # do that automatically).
    sshServe = {
      enable = isBuilder;
      protocol = "ssh-ng";
      write = true;
      trusted = true;
      keys = dispatchersSshPubKeys;
    };

    # ─── Build dispatcher (this node dispatches to remote builders) ──
    #
    # Gated on `isDispatcher`. `buildMachines` is sourced from
    # `horizon.node.builderConfigs`, a list of every ex-node
    # horizon-rs flagged `isBuilder`, with hostName, sshUser
    # (= "nix-ssh", matching the receiver above), sshKey
    # (= /etc/ssh/ssh_host_ed25519_key, the local host key as
    # daemon identity), supportedFeatures, system, maxJobs, and
    # publicHostKey/Line already populated. We only pin protocol
    # + speedFactor here as policy.
    distributedBuilds = isDispatcher;
    buildMachines = map (b: {
      inherit (b)
        hostName
        sshUser
        sshKey
        supportedFeatures
        system
        systems
        maxJobs
        ;
      protocol = "ssh-ng";
      speedFactor = 10;
      publicHostKey = b.publicHostKey;
    }) (optionals isDispatcher builderConfigs);

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
  };

  # known_hosts entries for every builder this dispatcher will
  # connect to. Without these, nix-daemon (no-TTY root context)
  # cannot answer the first-connection host-trust prompt and the
  # build silently hangs.
  programs.ssh.knownHosts = listToAttrs (
    map (b: {
      name = b.hostName;
      value.publicKey = b.publicHostKeyLine;
    }) (optionals isDispatcher builderConfigs)
  );

  users = {
    groups = {
      nixdev = { };
    }
    // (optionalAttrs isNixCache {
      nix-serve = {
        gid = 199;
      };
    });

    users = optionalAttrs isNixCache {
      nix-serve = {
        uid = 199;
        group = "nix-serve";
      };
    };
  };

  services.nix-serve = {
    enable = isNixCache;
    bindAddress = "";
    port = 80;
    secretKeyFile = "/var/lib/nix-serve/nix-secret-key";
  };

  systemd.services.nix-serve.serviceConfig = mkIf isNixCache {
    AmbientCapabilities = "CAP_NET_BIND_SERVICE";
    CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
  };
}
