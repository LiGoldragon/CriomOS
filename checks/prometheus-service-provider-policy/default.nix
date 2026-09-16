{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  configurationFor =
    providerConfiguration:
    lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/prometheus-service-provider.nix
        {
          system.stateVersion = "26.05";
          criomos.prometheusServiceProvider = providerConfiguration;
        }
      ];
    };

  disabled = (configurationFor { }).config;
  enabled =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
      tls = {
        certificatePath = "/run/secrets/prometheus-service-certificate";
        keyPath = "/run/secrets/prometheus-service-key";
      };
      reviewPipeline.enable = true;
    }).config;

  bool = value: if value then "true" else "false";
in
pkgs.runCommand "prometheus-service-provider-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool disabled.services.prosody.enable)} = false
  test ${lib.escapeShellArg (bool disabled.services.forgejo.enable)} = false
  test ${lib.escapeShellArg (bool enabled.services.prosody.enable)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.allowRegistration)} = false
  test ${lib.escapeShellArg (bool enabled.services.prosody.c2sRequireEncryption)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.s2sRequireEncryption)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.modules.pep)} = true
  test ${
    lib.escapeShellArg (bool enabled.services.prosody.virtualHosts."chat.example".enabled)
  } = true
  test ${
    lib.escapeShellArg enabled.services.prosody.virtualHosts."chat.example".ssl.cert
  } = /run/secrets/prometheus-service-certificate
  test ${
    lib.escapeShellArg enabled.services.prosody.virtualHosts."chat.example".ssl.key
  } = /run/secrets/prometheus-service-key
  test ${lib.escapeShellArg (bool enabled.services.forgejo.enable)} = true
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.DOMAIN} = git.example
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.PROTOCOL} = https
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.CERT_FILE} = /run/secrets/prometheus-service-certificate
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.KEY_FILE} = /run/secrets/prometheus-service-key
  test ${lib.escapeShellArg (bool enabled.services.forgejo.settings.service.DISABLE_REGISTRATION)} = true
  test ${lib.escapeShellArg (bool enabled.services.forgejo.settings.actions.ENABLED)} = true
  touch "$out"
''
