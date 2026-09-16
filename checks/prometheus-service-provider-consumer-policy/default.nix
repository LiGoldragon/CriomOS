{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  fixtureSecret = ../../fixtures/prometheus-service-provider-evaluation-only.sops.yaml;
  targetInputs = inputs // {
    secrets = {
      sopsFiles = {
        prosodyLiPassword = fixtureSecret;
        prosodyPersonaPassword = fixtureSecret;
      };
    };
  };

  configurationFor = horizon: configurationInputs:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inputs = configurationInputs;
        inherit horizon;
      };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/prometheus-service-provider.nix
        ../../modules/nixos/prometheus-service-provider-consumer.nix
        {
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/disk/by-label/fixture-root";
            fsType = "ext4";
          };
          boot.loader.grub.devices = [ "/dev/sda" ];
          sops.age.keyFile = "/run/keys/prometheus-service-provider-evaluation-only.age";
        }
      ];
    };

  targetHorizon = {
    cluster = "goldragon";
    node = { name = "prometheus"; };
  };
  wrongNodeHorizon = {
    cluster = "goldragon";
    node = { name = "ouranos"; };
  };
  wrongClusterHorizon = {
    cluster = "other";
    node = { name = "prometheus"; };
  };

  target = (configurationFor targetHorizon targetInputs).config;
  wrongNode = (configurationFor wrongNodeHorizon inputs).config;
  wrongCluster = (configurationFor wrongClusterHorizon inputs).config;
  targetToplevelEvaluated = builtins.deepSeq target.system.build.toplevel.drvPath true;
  wrongNodeToplevelEvaluated = builtins.deepSeq wrongNode.system.build.toplevel.drvPath true;
  wrongClusterToplevelEvaluated = builtins.deepSeq wrongCluster.system.build.toplevel.drvPath true;
  bool = value: if value then "true" else "false";
in
pkgs.runCommand "prometheus-service-provider-consumer-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool targetToplevelEvaluated)} = true
  test ${lib.escapeShellArg (bool wrongNodeToplevelEvaluated)} = true
  test ${lib.escapeShellArg (bool wrongClusterToplevelEvaluated)} = true

  test ${lib.escapeShellArg (bool target.criomos.prometheusServiceProvider.enable)} = true
  test ${lib.escapeShellArg target.criomos.prometheusServiceProvider.xmppDomain} = xmpp.goldragon.criome.net
  test ${lib.escapeShellArg (builtins.concatStringsSep "," target.criomos.prometheusServiceProvider.xmppDomainAliases)} = xmpp.goldragon.criome
  test ${lib.escapeShellArg (bool target.criomos.prometheusServiceProvider.forgejo.enable)} = false
  test ${lib.escapeShellArg (bool target.services.prosody.enable)} = true
  test ${lib.escapeShellArg (bool target.services.forgejo.enable)} = false
  test ${lib.escapeShellArg (bool (builtins.elem 5222 target.networking.firewall.allowedTCPPorts))} = true
  test ${lib.escapeShellArg (bool (builtins.elem 3000 target.networking.firewall.allowedTCPPorts))} = false
  test ${lib.escapeShellArg target.sops.secrets.prosody-li-password.format} = binary
  test ${lib.escapeShellArg target.sops.secrets.prosody-li-password.key} = ""
  test ${lib.escapeShellArg target.sops.secrets.prosody-persona-password.format} = binary
  test ${lib.escapeShellArg target.sops.secrets.prosody-persona-password.key} = ""
  test ${lib.escapeShellArg target.sops.secrets.prosody-li-password.mode} = 0400
  test ${lib.escapeShellArg target.sops.secrets.prosody-persona-password.mode} = 0400
  test ${lib.escapeShellArg target.sops.secrets.prosody-li-password.sopsFile} = ${lib.escapeShellArg fixtureSecret}
  test ${lib.escapeShellArg target.sops.secrets.prosody-persona-password.sopsFile} = ${lib.escapeShellArg fixtureSecret}

  test ${lib.escapeShellArg (bool wrongNode.criomos.prometheusServiceProvider.enable)} = false
  test ${lib.escapeShellArg (bool wrongCluster.criomos.prometheusServiceProvider.enable)} = false
  test ${lib.escapeShellArg (bool wrongNode.services.prosody.enable)} = false
  test ${lib.escapeShellArg (bool wrongCluster.services.prosody.enable)} = false
  test ${lib.escapeShellArg (bool (builtins.hasAttr "prosody-li-password" wrongNode.sops.secrets))} = false
  test ${lib.escapeShellArg (bool (builtins.hasAttr "prosody-persona-password" wrongCluster.sops.secrets))} = false
  touch "$out"
''
