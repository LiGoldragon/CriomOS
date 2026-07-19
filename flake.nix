{
  description = "CriomOS — NixOS platform consuming content-addressed flake inputs from lojix: `system` (the target tuple), `pkgs` (a stable wrapper flake that imports nixpkgs for that system), `horizon` (the per-deploy projected horizon JSON), and `deployment` (operation shape such as home-enabled vs home-off). Each axis caches independently in nix's flake-eval cache: pkgs eval is reused across deploys with the same system; horizon/deployment changes don't touch pkgs.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs?ref=main";

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

    # Keep the live coordination daemon on the self-healing v0.7.1 revision;
    # CriomOS-home follows this shared input rather than downgrading it.
    orchestrate.url = "github:LiGoldragon/orchestrate/9613b41271a015e898ff3da1bb86d75ba19176e5";
    orchestrate.inputs.nixpkgs.follows = "nixpkgs";

    # Home profile — its own repo, own inputs (niri, noctalia, stylix, emacs…).
    criomos-home.url = "github:LiGoldragon/CriomOS-home/c309f262343e922c00a1410f50c2aec8e2d23309";
    criomos-home.inputs.nixpkgs.follows = "nixpkgs";
    criomos-home.inputs.home-manager.follows = "home-manager";
    criomos-home.inputs.criomos-lib.follows = "criomos-lib";
    criomos-home.inputs.rust-overlay.follows = "rust-overlay";
    criomos-home.inputs.horizon.follows = "horizon";
    criomos-home.inputs.system.follows = "system";
    criomos-home.inputs.pkgs.follows = "pkgs";
    criomos-home.inputs.lojix.follows = "lojix";
    criomos-home.inputs.orchestrate.follows = "orchestrate";
    # Unify the spirit input with CriomOS's own, completing the shared-input
    # follows set above. CriomOS-home's home modules receive CriomOS-home's
    # flake inputs (userHomes.nix keeps `inputs` out of extraSpecialArgs), so
    # the system-embedded home builds its guardian-carrying spirit package from
    # THIS input. Following it onto CriomOS's `spirit` pin makes the guardian
    # prompt the System Switch bakes reboot-persistent identical to the spirit
    # the system spirit daemon runs — one spirit revision for the whole closure.
    criomos-home.inputs.spirit.follows = "spirit";

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

    # Spirit journal daemon — the durable versioned intent record log.
    # Consumed by modules/nixos/spirit.nix on nodes carrying a spirit service.
    spirit.url = "github:LiGoldragon/spirit";
    spirit.inputs.nixpkgs.follows = "nixpkgs";

    # Daemon-based deploy orchestrator. Installed on operator/development hosts
    # so parity checks use the same installed service/socket path as production.
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
      blueprintOutputs = inputs.blueprint { inherit inputs; };

      horizon = inputs.horizon.horizon;
      pkgs = inputs.pkgs.pkgs;
      system = inputs.system.system;
      deployment =
        inputs.deployment.deployment or {
          includeHome = true;
          includeAllFirmware = true;
        };
      includeHome = deployment.includeHome or true;

      criomos-lib = inputs.criomos-lib.lib;
      constants = criomos-lib.constants;
      blueprintChecks = inputs.nixpkgs.lib.mapAttrs (
        _: checks: inputs.nixpkgs.lib.filterAttrs (_: inputs.nixpkgs.lib.isDerivation) checks
      ) (blueprintOutputs.checks or { });
      projectChecks = blueprintChecks // {
        ${system} = (blueprintChecks.${system} or { }) // {
          headscale-selfsigned-cert = pkgs.callPackage ./checks/headscale-selfsigned-cert {
            inherit inputs;
          };
          image-exchange-keys-scoped-to-co-hosts =
            pkgs.callPackage ./checks/image-exchange-keys-scoped-to-co-hosts
              {
                inherit inputs;
              };
          bluetooth-resume-power-policy = pkgs.callPackage ./checks/bluetooth-resume-power-policy {
            inherit inputs;
          };
          desktop-audio-policy = pkgs.callPackage ./checks/desktop-audio-policy { inherit inputs; };
          devshell-repository-layout = pkgs.callPackage ./checks/devshell-repository-layout { };
          laptop-keyboard-keyd = pkgs.callPackage ./checks/laptop-keyboard-keyd { inherit inputs; };
          legacy-chroma-runtime = pkgs.callPackage ./checks/legacy-chroma-runtime { };
          metal-firmware-policy = pkgs.callPackage ./checks/metal-firmware-policy { inherit inputs; };
          nspawn-role-policy = pkgs.callPackage ./checks/nspawn-role-policy { inherit inputs; };
          nix-role-policy = pkgs.callPackage ./checks/nix-role-policy { inherit inputs; };
          repository-receive-role-policy = pkgs.callPackage ./checks/repository-receive-role-policy {
            inherit inputs;
          };
          mirror-role-policy = pkgs.callPackage ./checks/mirror-role-policy { inherit inputs; };
          lojix-daemon-config-roundtrip = pkgs.callPackage ./checks/lojix-daemon-config-roundtrip {
            inherit inputs;
          };
          criome-daemon-config-roundtrip = pkgs.callPackage ./checks/criome-daemon-config-roundtrip {
            inherit inputs;
          };
          spirit-role-policy = pkgs.callPackage ./checks/spirit-role-policy { inherit inputs; };
          persona-router-role-policy = pkgs.callPackage ./checks/persona-router-role-policy {
            inherit inputs;
          };
          resolver-role-policy = pkgs.callPackage ./checks/resolver-role-policy { inherit inputs; };
          vm-testing-prometheus-policy = pkgs.callPackage ./checks/vm-testing-prometheus-policy {
            inherit inputs;
          };
          router-wifi-horizon-policy = pkgs.callPackage ./checks/router-wifi-horizon-policy { };
          router-wifi-secret = pkgs.callPackage ./checks/router-wifi-secret { };
          wireguard-untrusted-proxy = pkgs.callPackage ./checks/wireguard-untrusted-proxy { inherit inputs; };
        };
      };

      target = inputs.nixpkgs.lib.nixosSystem {
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
        ]
        ++ inputs.nixpkgs.lib.optionals includeHome [
          inputs.home-manager.nixosModules.home-manager
        ]
        ++ [
          inputs.self.nixosModules.criomos
        ];
      };
    in
    blueprintOutputs
    // {
      checks = projectChecks;

      homeConfigurations = inputs.criomos-home.homeConfigurations;

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
