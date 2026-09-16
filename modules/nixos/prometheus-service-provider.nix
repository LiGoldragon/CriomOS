{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.criomos.prometheusServiceProvider;
  reviewSource = "github:LiGoldragon/CriomOS";
  reviewRunner = pkgs.writeShellApplication {
    name = "prometheus-nix-review-runner";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./prometheus-nix-review-runner.sh;
  };
in
{
  options.criomos.prometheusServiceProvider = {
    enable = mkEnableOption "the Prometheus source-only service-provider proof of concept";

    xmppDomain = mkOption {
      type = types.str;
      default = "";
      description = "XMPP domain served by Prosody when this POC is enabled.";
    };

    forgejoDomain = mkOption {
      type = types.str;
      default = "";
      description = "Public Forgejo domain when this POC is enabled.";
    };

    tls = {
      certificatePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime certificate path, normally config.sops.secrets.<name>.path from a deployment-owned secret declaration.";
      };

      keyPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime private-key path, normally config.sops.secrets.<name>.path from a deployment-owned secret declaration.";
      };
    };

    reviewRunner = {
      enable = mkEnableOption "a manually-started, bounded native Nix review runner";

      sourceRevision = mkOption {
        type = types.enum [ "7c9975afbcf44cb580d1491e7f8447fd1def1fbd" ];
        default = "7c9975afbcf44cb580d1491e7f8447fd1def1fbd";
        description = "Allowlisted immutable CriomOS revision for the review runner.";
      };

      resultPath = mkOption {
        type = types.enum [ "/var/lib/prometheus-nix-review/result.json" ];
        default = "/var/lib/prometheus-nix-review/result.json";
        description = "Bounded structured result artifact retained for human review.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.xmppDomain != "";
        message = "criomos.prometheusServiceProvider.xmppDomain is required when enabled";
      }
      {
        assertion = cfg.forgejoDomain != "";
        message = "criomos.prometheusServiceProvider.forgejoDomain is required when enabled";
      }
      {
        assertion = (cfg.tls.certificatePath == null) == (cfg.tls.keyPath == null);
        message = "criomos.prometheusServiceProvider.tls requires both certificatePath and keyPath";
      }
      {
        assertion = cfg.tls.certificatePath != null;
        message = "criomos.prometheusServiceProvider.tls requires deployment-owned runtime TLS paths when enabled";
      }
    ];

    # PEP is the Prosody publication mechanism needed by OMEMO-capable clients:
    # https://prosody.im/doc/modules/mod_pep. It does not establish an
    # end-to-end-encryption implementation or client interoperability claim.
    # No chime bot is configured here; a bot/library and its encrypted-message
    # handling remain a separately verified integration boundary.
    services.prosody = {
      enable = true;
      allowRegistration = false;
      c2sRequireEncryption = true;
      s2sRequireEncryption = true;
      s2sInsecureDomains = [ ];
      # This narrowly scoped POC does not provision MUC or HTTP file sharing,
      # so it explicitly declines the XEP-0423 compliance-suite promise.
      xmppComplianceSuite = false;
      modules.pep = true;
      virtualHosts.${cfg.xmppDomain} = {
        domain = cfg.xmppDomain;
        enabled = true;
      }
      // lib.optionalAttrs (cfg.tls.certificatePath != null) {
        ssl = {
          cert = cfg.tls.certificatePath;
          key = cfg.tls.keyPath;
        };
      };
    };

    services.forgejo = {
      enable = true;
      settings = {
        server = {
          DOMAIN = cfg.forgejoDomain;
          ROOT_URL = "https://${cfg.forgejoDomain}/";
          PROTOCOL = "https";
          CERT_FILE = cfg.tls.certificatePath;
          KEY_FILE = cfg.tls.keyPath;
        };
        service.DISABLE_REGISTRATION = true;
        # This advertises review workflows but does not register a Forgejo
        # account or runner. The bounded unit below is manually started.
        actions.ENABLED = cfg.reviewRunner.enable;
      };
    };

    systemd.services.prometheus-nix-review = mkIf cfg.reviewRunner.enable {
      description = "Bounded Prometheus native Nix review";
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "15min";
        KillMode = "control-group";
        ExecStart = "${reviewRunner}/bin/prometheus-nix-review-runner ${lib.getExe config.nix.package} ${cfg.reviewRunner.resultPath} ${reviewSource} ${cfg.reviewRunner.sourceRevision}";
        StateDirectory = "prometheus-nix-review";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/prometheus-nix-review" ];
      };
    };
  };
}
