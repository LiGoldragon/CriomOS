{
  description = "CriomOS — NixOS platform consuming content-addressed flake inputs from lojix: `system` (the target tuple), `pkgs` (a stable wrapper flake that imports nixpkgs for that system), `horizon` (the per-deploy projected horizon JSON), and `deployment` (operation shape such as home-enabled vs home-off). Each axis caches independently in nix's flake-eval cache: pkgs eval is reused across deploys with the same system; horizon/deployment changes don't touch pkgs.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs";

    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Shared Rust build flake — fenix-locked nightly toolchain (no
    # per-crate rust-stable channel hash). Top-level so every LiGoldragon
    # crate input that declares its own `rust-build` is forced onto this
    # one nightly build via `follows`, retiring the stale per-crate hash.
    rust-build.url = "github:LiGoldragon/rust-build";
    rust-build.inputs.nixpkgs.follows = "nixpkgs";

    # Shared constants, helpers, and cross-repo data. Consumed by both
    # CriomOS and CriomOS-home.
    criomos-lib.url = "github:LiGoldragon/CriomOS-lib";

    # Orchestrate Nexus owns its per-user default Sema store and ordinary/meta
    # XDG sockets. CriomOS-home follows this shared immutable release.
    orchestrate.url = "github:LiGoldragon/orchestrate";
    orchestrate.inputs.nixpkgs.follows = "nixpkgs";

    # Home profile — its own repo, own inputs (niri, noctalia, stylix, emacs…).
    criomos-home.url = "github:LiGoldragon/CriomOS-home";
    criomos-home.inputs.nixpkgs.follows = "nixpkgs";
    criomos-home.inputs.home-manager.follows = "home-manager";
    criomos-home.inputs.criomos-lib.follows = "criomos-lib";
    criomos-home.inputs.rust-overlay.follows = "rust-overlay";
    criomos-home.inputs.horizon.follows = "horizon";
    criomos-home.inputs.system.follows = "system";
    criomos-home.inputs.pkgs.follows = "pkgs";
    criomos-home.inputs.orchestrate.follows = "orchestrate";
    criomos-home.inputs.messenger-clj.follows = "messenger-clj";
    # Unify Home with CriomOS's one maintained Spirit release. The Spirit flake
    # owns the daemon, judge, judge configuration, provider, contracts, and user
    # service artifact composition; Home consumes that interface without
    # independently pinning any Spirit service component.
    criomos-home.inputs.spirit.follows = "spirit";

    messenger-clj.url = "github:LiGoldragon/messenger-clj";
    messenger-clj.inputs.nixpkgs.follows = "nixpkgs";

    # Backlight + idle-dim daemon. Consumed in modules/nixos/metal/.
    brightness-ctl.url = "github:LiGoldragon/brightness-ctl";
    brightness-ctl.inputs.nixpkgs.follows = "nixpkgs";

    # microvm.nix — declarative persistent lightweight guests. Substrate for
    # the VM-testing node feature's always-on routed test VM (the
    # vm-testing.<cluster>.criome endpoint). Consumed in
    # modules/nixos/vm-testing/. Per design report 67 §"Persistent VM
    # substrate" (chosen default: input = yes).
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";

    # Repository event ledger. Consumed by modules/nixos/repository-receive.nix
    # on persona-development hosts.
    repository-ledger.url = "github:LiGoldragon/repository-ledger";
    repository-ledger.inputs.nixpkgs.follows = "nixpkgs";

    # SEMA version-control mirror daemon. Consumed by modules/nixos/mirror.nix
    # on persona-development hosts that join the cluster tailnet.
    mirror.url = "github:LiGoldragon/mirror";
    mirror.inputs.nixpkgs.follows = "nixpkgs";

    # Persona message/signal router daemon (router-daemon) — the
    # daemon-to-daemon delivery fabric, NOT the WiFi router in
    # modules/nixos/router/. Consumed by modules/nixos/persona-router.nix on
    # nodes carrying the PersonaRouter node service. Pinned to the criome-auth
    # integration branch (real criome attestation + node-identity forward path);
    # main landing: the criome-auth witness forward family is on router main.
    router.url = "github:LiGoldragon/router";
    router.inputs.nixpkgs.follows = "nixpkgs";

    # criome BLS-attestation daemon. Consumed by modules/nixos/criome.nix on
    # nodes carrying a criome service. On main: configurable distinct
    # node_identity + group-accessible working socket.
    criome.url = "github:LiGoldragon/criome";
    criome.inputs.nixpkgs.follows = "nixpkgs";

    # Maintained Spirit release — the single pin authority for the daemon,
    # judge, configuration, provider, contracts, and service artifacts.
    # Consumed directly by the NixOS module and followed by CriomOS-home.
    spirit.url = "github:LiGoldragon/spirit";
    spirit.inputs.nixpkgs.follows = "nixpkgs";

    # Lojix Nexus — deployment authority. Its executable owns the default
    # state directory, store file and both socket paths; the NixOS module
    # restates them rather than setting them.
    # 6.0.0, carrying exactly one revision of every contract crate —
    # `signal-lojix` 5.0.0 (4271b5ce), `meta-signal-lojix` 6.0.0 (35deec4e),
    # `horizon-lib` 0.10.1 (40d04d25) — so the duplicate `meta-signal-lojix`
    # that made 23f09f28 uncompilable cannot recur. The Nexus announces
    # `(LojixNexusReady <ordinary> <meta>)` once both listeners are bound, and
    # its own startup test now waits for that announcement instead of polling a
    # five-second deadline: 5.0.0's test failed reproducibly on a loaded remote
    # builder while passing on an idle one.
    lojix.url = "github:LiGoldragon/lojix";
    lojix.inputs.nixpkgs.follows = "nixpkgs";

    # GPG → X.509 cert tool for WiFi PKI + node identity complex.
    # Consumed in modules/nixos/complex.nix.
    clavifaber.url = "github:LiGoldragon/clavifaber";
    clavifaber.inputs.nixpkgs.follows = "nixpkgs";
    # clavifaber is the only direct LiGoldragon crate input that declares
    # a `rust-build` input — force it onto the top-level nightly rust-build.
    # brightness-ctl, lojix, mirror, repository-ledger build via crane+fenix
    # directly (no rust-build input), so they take no follows here.
    clavifaber.inputs.rust-build.follows = "rust-build";

    # System tuple — lojix produces a tiny content-addressed flake
    # whose only output is `system = "x86_64-linux"` (or aarch64).
    system.url = "path:./stubs/no-system";

    # Pkgs flake — instantiates nixpkgs for the given (nixpkgs-rev,
    # system) tuple, plus our overlays. Its own repo so CriomOS source
    # edits don't invalidate the pkgs eval cache (root-flake-keyed).
    # nixpkgs + system propagate via `follows` so the pkgs flake sees
    # the same revisions CriomOS does.
    pkgs.url = "github:LiGoldragon/CriomOS-pkgs";
    pkgs.inputs.nixpkgs.follows = "nixpkgs";
    pkgs.inputs.system.follows = "system";

    # Horizon — the projected (cluster, node) view. lojix overrides
    # per deploy.
    horizon.url = "path:./stubs/no-horizon";

    # Deployment shape — lojix overrides per request. The default keeps
    # the historical full system+home target.
    deployment.url = "path:./stubs/default-deployment";

    # Encrypted cluster secrets — lojix overrides per deploy from the
    # cluster repository.
    secrets.url = "path:./stubs/no-secrets";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      # Host toplevels are deploy artefacts that Lojix evaluates, not checks.
      # Blueprint turns every nixosConfigurations entry into a nixos-* check and
      # must evaluate the host to list it, so it is not shown the host at all.
      blueprintOutputs = inputs.blueprint {
        inputs = inputs // {
          self = inputs.self // {
            nixosConfigurations = { };
          };
        };
      };

      # Bootstrap is a maintained operator app, not a target-system output.
      # Publish it for the supported Nix platforms without forcing the
      # deliberately-throwing `system` deployment stub used by the OS surface.
      bootstrapSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      bootstrapPackages = lib.genAttrs bootstrapSystems (bootstrapSystem: {
        lojix-bootstrap = inputs.lojix.packages.${bootstrapSystem}.lojix-bootstrap;
      });
      bootstrapApps = lib.genAttrs bootstrapSystems (bootstrapSystem: {
        lojix-bootstrap = inputs.lojix.apps.${bootstrapSystem}.lojix-bootstrap;
      });

      horizon = inputs.horizon.horizon;
      system = inputs.system.system;
      # Consume CriomOS-home's explicit package-set boundary.  Forcing a
      # standalone Home configuration here bypasses this Consumer's concrete
      # user policy and can fail before the materialized target is evaluated.
      pkgs = inputs.criomos-home.legacyPackages.${system};
      deployment =
        inputs.deployment.deployment or {
          includeHome = true;
          includeAllFirmware = true;
        };
      includeHome = deployment.includeHome or true;

      criomos-lib = inputs.criomos-lib.lib;
      constants = criomos-lib.constants;
      blueprintChecks = lib.mapAttrs (_: checks: lib.filterAttrs (_: lib.isDerivation) checks) (
        blueprintOutputs.checks or { }
      );
      # Project checks share one flake context; keep that wiring in one place.
      callCheck = path: pkgs.callPackage path { inherit inputs; };
      projectChecks = blueprintChecks // {
        ${system} = (blueprintChecks.${system} or { }) // {
          tailnet-declaration = callCheck ./checks/tailnet-declaration;
          tailnet-enrollment = callCheck ./checks/tailnet-enrollment;
          image-exchange-keys-scoped-to-co-hosts = callCheck ./checks/image-exchange-keys-scoped-to-co-hosts;
          bluetooth-resume-power-policy = callCheck ./checks/bluetooth-resume-power-policy;
          desktop-audio-policy = callCheck ./checks/desktop-audio-policy;
          clavifaber-publication-request = callCheck ./checks/clavifaber-publication-request;
          devshell-repository-layout = callCheck ./checks/devshell-repository-layout;
          laptop-keyboard-keyd = callCheck ./checks/laptop-keyboard-keyd;
          legacy-chroma-runtime = callCheck ./checks/legacy-chroma-runtime;
          metal-firmware-policy = callCheck ./checks/metal-firmware-policy;
          metal-model-classification = callCheck ./checks/metal-model-classification;
          fixed-location-policy = callCheck ./checks/fixed-location-policy;
          ms2130-uvc-aspect-quirk = callCheck ./checks/ms2130-uvc-aspect-quirk;
          nspawn-role-policy = callCheck ./checks/nspawn-role-policy;
          nix-role-policy = callCheck ./checks/nix-role-policy;
          flake-registry-shape = callCheck ./checks/flake-registry-shape;
          repository-receive-role-policy = callCheck ./checks/repository-receive-role-policy;
          mirror-role-policy = callCheck ./checks/mirror-role-policy;
          lojix-nexus-service = callCheck ./checks/lojix-nexus-service;
          lojix-nexus-start = callCheck ./checks/lojix-nexus-start;
          lojix-ownership = callCheck ./checks/lojix-ownership;
          lojix-fresh-nexus-startup = inputs.lojix.checks.${system}.fresh-daemon-startup;
          criome-daemon-config-roundtrip = callCheck ./checks/criome-daemon-config-roundtrip;
          spirit-role-policy = callCheck ./checks/spirit-role-policy;
          opencode-testing-policy = callCheck ./checks/opencode-testing-policy;
          persona-router-role-policy = callCheck ./checks/persona-router-role-policy;
          resolver-role-policy = callCheck ./checks/resolver-role-policy;
          vm-testing-prometheus-policy = callCheck ./checks/vm-testing-prometheus-policy;
          router-wifi-horizon-policy = callCheck ./checks/router-wifi-horizon-policy;
          router-wifi-radio = callCheck ./checks/router-wifi-radio;
          router-non-router-lazy = callCheck ./checks/router-non-router-lazy;
          router-wifi-secret = callCheck ./checks/router-wifi-secret;
          router-wan-recovery = callCheck ./checks/router-wan-recovery;
          router-yggdrasil-ndp = callCheck ./checks/router-yggdrasil-ndp;
          router-declared-tcp-ports = callCheck ./checks/router-declared-tcp-ports;
          usb-downlink = callCheck ./checks/usb-downlink;
          usb-uplink = callCheck ./checks/usb-uplink;
          usb-downlink-chain = callCheck ./checks/usb-downlink-chain;
          usb-downlink-observer = callCheck ./checks/usb-downlink-observer;
          wireguard-untrusted-proxy = callCheck ./checks/wireguard-untrusted-proxy;
          wispr-keyboard-uaccess = callCheck ./checks/wispr-keyboard-uaccess;
          home-activation-equivalence = import ./home-activation-equivalence.nix {
            inherit
              pkgs
              inputs
              target
              homeConfigurations
              ;
          };
        };
      };

      target = lib.nixosSystem {
        # `system` is derived from `pkgs.stdenv.hostPlatform.system`
        # when `pkgs` is supplied; passing it explicitly would set
        # `nixpkgs.system`, which `readOnlyPkgs` has removed.
        inherit pkgs;
        specialArgs = {
          inherit
            horizon
            system
            deployment
            inputs
            constants
            criomos-lib
            ;
        };
        modules = [
          inputs.nixpkgs.nixosModules.readOnlyPkgs
          { system.configurationRevision = inputs.self.rev or null; }
        ]
        ++ lib.optionals includeHome [
          inputs.home-manager.nixosModules.home-manager
        ]
        ++ [
          inputs.self.nixosModules.criomos
        ];
      };

      # A user-environment deployment must consume the exact Home Manager
      # activation package embedded in the materialized NixOS target. Export
      # the conventional `homeConfigurations.<user>.activationPackage` shape
      # as a projection of that target rather than evaluating CriomOS-home a
      # second, differently configured way.
      homeConfigurations = lib.mapAttrs (_: userConfiguration: {
        activationPackage = userConfiguration.home.activationPackage;
      }) target.config.home-manager.users;

      # The pinned CriomOS-home flake's own output surface, exposed separately
      # so deployment evidence can compare it with the embedded NixOS Home
      # Manager activation package without turning a projection into its own
      # witness. Its follows inherit materialized horizon/system inputs.
      independentHomeConfigurations = inputs.criomos-home.homeConfigurations;
    in
    blueprintOutputs
    // {
      checks = projectChecks;

      # Exact maintained bootstrap re-export.  This is a flake-owned app, not
      # a service wrapper: every authority-bearing bootstrap value stays in
      # the one inline Lojix request.
      packages = lib.recursiveUpdate (blueprintOutputs.packages or { }) bootstrapPackages;

      apps = lib.recursiveUpdate (blueprintOutputs.apps or { }) bootstrapApps;

      inherit homeConfigurations;
      inherit independentHomeConfigurations;

      nixosConfigurations.target = target;

      # For cache-property testing — exposes the parsed horizon
      # without going through nixosSystem evaluation.
      horizonProbe = horizon;

      # Likewise for the pkgs axis — cheap probe that forces a
      # pkgs evaluation through the pkgs-flake input. Same `system`
      # input → cached across deploys.
      pkgsProbe = pkgs.stdenv.hostPlatform.system;
    };
}
