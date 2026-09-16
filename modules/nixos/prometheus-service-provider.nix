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
    optional
    types
    ;
  cfg = config.criomos.prometheusServiceProvider;
  reviewSource = "github:LiGoldragon/CriomOS";
  generatedTlsDirectory = "/var/lib/prometheus-service-tls";
  generatedCertificatePath = "${generatedTlsDirectory}/current/certificate.pem";
  generatedKeyPath = "${generatedTlsDirectory}/current/key.pem";
  certificateSecretName = "prometheus-service-certificate";
  keySecretName = "prometheus-service-key";
  forgejoEnabled = cfg.enable && cfg.forgejo.enable;
  usingSops = cfg.enable && cfg.tls.sopsFileKey != null;
  # The secrets input remains lazy for disabled and self-signed configurations.
  sopsFiles = if usingSops then (inputs.secrets.sopsFiles or { }) else { };
  sopsFileExists = usingSops && builtins.hasAttr cfg.tls.sopsFileKey sopsFiles;
  certificatePath =
    if usingSops && sopsFileExists then config.sops.secrets.${certificateSecretName}.path
    else if usingSops then "/run/secrets/prometheus-service-certificate-unavailable"
    else if cfg.tls.certificatePath == null then generatedCertificatePath
    else cfg.tls.certificatePath;
  keyPath =
    if usingSops && sopsFileExists then config.sops.secrets.${keySecretName}.path
    else if usingSops then "/run/secrets/prometheus-service-key-unavailable"
    else if cfg.tls.keyPath == null then generatedKeyPath
    else cfg.tls.keyPath;
  generatedTls = !usingSops && cfg.tls.certificatePath == null && cfg.tls.generateSelfSigned;
  xmppCertificateNames = [ cfg.xmppDomain ] ++ cfg.xmppDomainAliases;
  certificateNames = xmppCertificateNames ++ optional forgejoEnabled cfg.forgejo.domain;
  certificateNameArgs = lib.concatMapStringsSep " " lib.escapeShellArg certificateNames;
  serviceUnits = [ "prosody.service" ] ++ optional forgejoEnabled "forgejo.service";
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

    xmppDomainAliases = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "DNS aliases for the XMPP certificate; these names do not create additional Prosody virtual hosts.";
    };

    forgejo = {
      enable = mkEnableOption "the separate Forgejo service";

      domain = mkOption {
        type = types.str;
        default = "";
        description = "Public Forgejo domain when the separate Forgejo service is enabled.";
      };

      httpsPort = mkOption {
        type = types.port;
        default = 3000;
        description = "TCP port on which the separate Forgejo service serves HTTPS.";
      };
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
        assertion = lib.all (domain: domain != "") cfg.xmppDomainAliases;
        message = "criomos.prometheusServiceProvider.xmppDomainAliases cannot contain empty names";
      }
      {
        assertion = lib.all (domain: domain != cfg.xmppDomain) cfg.xmppDomainAliases;
        message = "criomos.prometheusServiceProvider.xmppDomainAliases must differ from xmppDomain";
      }
      {
        assertion = !forgejoEnabled || cfg.forgejo.domain != "";
        message = "criomos.prometheusServiceProvider.forgejo.domain is required when Forgejo is enabled";
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
    users.groups.prometheus-service-tls.members = [ "prosody" ] ++ optional forgejoEnabled "forgejo";

    sops.secrets = lib.mkIf (usingSops && sopsFileExists) {
      ${certificateSecretName} = {
        sopsFile = sopsFiles.${cfg.tls.sopsFileKey};
        key = "certificate";
        format = "yaml";
        owner = "root";
        group = "prometheus-service-tls";
        mode = "0440";
        restartUnits = serviceUnits;
      };
      ${keySecretName} = {
        sopsFile = sopsFiles.${cfg.tls.sopsFileKey};
        key = "key";
        format = "yaml";
        owner = "root";
        group = "prometheus-service-tls";
        mode = "0440";
        restartUnits = serviceUnits;
      };
    };

    systemd.services.prometheus-service-tls = mkIf generatedTls {
      description = "Prepare Prometheus service self-signed TLS certificate";
      before = [
        "prosody.service"
      ] ++ optional forgejoEnabled "forgejo.service";
      requiredBy = [ "prosody.service" ] ++ optional forgejoEnabled "forgejo.service";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "prometheus-service-tls";
        UMask = "0027";
      };
      script = ''
        install -d -m 0750 -o root -g prometheus-service-tls ${generatedTlsDirectory}
        previous="$(readlink ${generatedTlsDirectory}/current 2>/dev/null || true)"
        ${tlsPreparation}/bin/prometheus-service-tls ${generatedCertificatePath} ${generatedKeyPath} ${certificateNameArgs}
        current="$(readlink ${generatedTlsDirectory}/current)"
        if [ -n "$previous" ] && [ "$previous" != "$current" ]; then
          ${pkgs.systemd}/bin/systemctl --no-block try-reload-or-restart ${lib.concatStringsSep " " serviceUnits}
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

    systemd.services.forgejo = mkIf (generatedTls && forgejoEnabled) {
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

    services.forgejo = mkIf forgejoEnabled {
      enable = true;
      settings = {
        server = {
          DOMAIN = cfg.forgejo.domain;
          ROOT_URL = "https://${cfg.forgejo.domain}:${toString cfg.forgejo.httpsPort}/";
          PROTOCOL = "https";
          HTTP_PORT = cfg.forgejo.httpsPort;
          CERT_FILE = certificatePath;
          KEY_FILE = keyPath;
        };
        service.DISABLE_REGISTRATION = true;
        # No Forgejo runner is provisioned or registered by this POC. The
        # bounded review unit remains manually started, so Actions must not
        # advertise an unsupported workflow surface.
        actions.ENABLED = false;
      };
    };

    # Prosody's client-to-server listener is 5222. Forgejo serves HTTPS on
    # forgejo.httpsPort only when that separate service is enabled; no
    # administrative or runner ports are exposed.
    networking.firewall.allowedTCPPorts = [ 5222 ] ++ optional forgejoEnabled cfg.forgejo.httpsPort;

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
