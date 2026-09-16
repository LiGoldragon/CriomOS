{
  config,
  lib,
  pkgs,
  inputs,
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
  generatedTlsDirectory = "/var/lib/prometheus-service-tls";
  generatedCertificatePath = "${generatedTlsDirectory}/current/certificate.pem";
  generatedKeyPath = "${generatedTlsDirectory}/current/key.pem";
  certificateSecretName = "prometheus-service-certificate";
  keySecretName = "prometheus-service-key";
  usingSops = cfg.enable && cfg.tls.sopsFileKey != null;
  # The secrets input remains lazy for disabled and self-signed configurations.
  sopsFiles = if usingSops then inputs.secrets.sopsFiles else { };
  sopsFileExists = usingSops && builtins.hasAttr cfg.tls.sopsFileKey sopsFiles;
  certificatePath =
    if usingSops then config.sops.secrets.${certificateSecretName}.path
    else if cfg.tls.certificatePath == null then generatedCertificatePath
    else cfg.tls.certificatePath;
  keyPath =
    if usingSops then config.sops.secrets.${keySecretName}.path
    else if cfg.tls.keyPath == null then generatedKeyPath
    else cfg.tls.keyPath;
  generatedTls = !usingSops && cfg.tls.certificatePath == null && cfg.tls.generateSelfSigned;
  tlsPreparation = pkgs.writeShellApplication {
    name = "prometheus-service-tls";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    text = builtins.readFile ./prometheus-service-tls.sh;
  };
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

      generateSelfSigned = mkOption {
        type = types.bool;
        default = true;
        description = "Generate a short-lived runtime certificate when no deployment-owned TLS paths are supplied.";
      };

      sopsFileKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Key in inputs.secrets.sopsFiles for an encrypted YAML fixture with certificate and key fields; null retains explicit paths or self-signed TLS.";
      };
    };

    reviewRunner = {
      enable = mkEnableOption "a manually-started, bounded native Nix review runner";

      sourceRevision = mkOption {
        type = types.enum [ "7ee784103dac929bda499875a98504fd15ca6523" ];
        default = "7ee784103dac929bda499875a98504fd15ca6523";
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
        assertion = cfg.tls.sopsFileKey == null || (cfg.tls.certificatePath == null && cfg.tls.keyPath == null);
        message = "criomos.prometheusServiceProvider.tls.sopsFileKey conflicts with explicit certificatePath or keyPath";
      }
      {
        assertion = !usingSops || sopsFileExists;
        message = "criomos.prometheusServiceProvider.tls.sopsFileKey is missing from inputs.secrets.sopsFiles";
      }
      {
        assertion = usingSops || cfg.tls.certificatePath != null || cfg.tls.generateSelfSigned;
        message = "criomos.prometheusServiceProvider.tls requires deployment-owned runtime TLS paths, sopsFileKey, or generateSelfSigned";
      }
    ];

    # PEP is the Prosody publication mechanism needed by OMEMO-capable clients:
    # https://prosody.im/doc/modules/mod_pep. It does not establish an
    # end-to-end-encryption implementation or client interoperability claim.
    # No chime bot is configured here; a bot/library and its encrypted-message
    # handling remain a separately verified integration boundary.
    users.groups.prometheus-service-tls.members = [
      "prosody"
      "forgejo"
    ];

    sops.secrets = lib.mkIf (usingSops && sopsFileExists) {
      ${certificateSecretName} = {
        sopsFile = sopsFiles.${cfg.tls.sopsFileKey};
        key = "certificate";
        format = "yaml";
        owner = "root";
        group = "prometheus-service-tls";
        mode = "0440";
        restartUnits = [ "prosody.service" "forgejo.service" ];
      };
      ${keySecretName} = {
        sopsFile = sopsFiles.${cfg.tls.sopsFileKey};
        key = "key";
        format = "yaml";
        owner = "root";
        group = "prometheus-service-tls";
        mode = "0440";
        restartUnits = [ "prosody.service" "forgejo.service" ];
      };
    };

    systemd.services.prometheus-service-tls = mkIf generatedTls {
      description = "Prepare Prometheus service self-signed TLS certificate";
      before = [
        "prosody.service"
        "forgejo.service"
      ];
      requiredBy = [
        "prosody.service"
        "forgejo.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "prometheus-service-tls";
        UMask = "0027";
      };
      script = ''
        install -d -m 0750 -o root -g prometheus-service-tls ${generatedTlsDirectory}
        previous="$(readlink ${generatedTlsDirectory}/current 2>/dev/null || true)"
        ${tlsPreparation}/bin/prometheus-service-tls ${generatedCertificatePath} ${generatedKeyPath} ${lib.escapeShellArg cfg.xmppDomain} ${lib.escapeShellArg cfg.forgejoDomain}
        current="$(readlink ${generatedTlsDirectory}/current)"
        if [ -n "$previous" ] && [ "$previous" != "$current" ]; then
          ${pkgs.systemd}/bin/systemctl --no-block try-reload-or-restart prosody.service forgejo.service
        fi
      '';
    };

    systemd.timers.prometheus-service-tls = mkIf generatedTls {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "weekly"; Persistent = true; };
    };

    systemd.services.prosody = mkIf generatedTls {
      requires = [ "prometheus-service-tls.service" ];
      after = [ "prometheus-service-tls.service" ];
    };

    systemd.services.forgejo = mkIf generatedTls {
      requires = [ "prometheus-service-tls.service" ];
      after = [ "prometheus-service-tls.service" ];
    };

    services.prosody = {
      enable = true;
      allowRegistration = false;
      c2sRequireEncryption = true;
      s2sRequireEncryption = true;
      s2sInsecureDomains = [ ];
      # This narrowly scoped POC does not provision MUC or HTTP file sharing,
      # so it explicitly declines the XEP-0423 compliance-suite promise.
      xmppComplianceSuite = false;
      modules = {
        pep = true;
        # These server modules support offline synchronization but do not prove
        # an OMEMO 2 client or bot end-to-end workflow.
        mam = true;
        carbons = true;
        smacks = true;
      };
      virtualHosts.${cfg.xmppDomain} = {
        domain = cfg.xmppDomain;
        enabled = true;
      }
      // lib.optionalAttrs (true) {
        ssl = {
          cert = certificatePath;
          key = keyPath;
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
          CERT_FILE = certificatePath;
          KEY_FILE = keyPath;
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
