{ config, lib, ... }:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.criomos.prometheusServiceProvider;
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

    reviewPipeline = {
      enable = mkEnableOption "Forgejo Actions metadata for the native Nix review-pipeline POC";

      checkAttribute = mkOption {
        type = types.str;
        default = ".#checks.x86_64-linux.prometheus-service-provider-policy";
        description = "Flake check attribute a future isolated Forgejo runner must evaluate.";
      };

      command = mkOption {
        type = types.str;
        default = "nix flake check --no-build";
        description = "Native Nix command recorded for a future isolated review runner.";
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
      modules.pep = true;
      virtualHosts.${cfg.xmppDomain} = {
        domain = cfg.xmppDomain;
        enabled = true;
      };
    };

    services.forgejo = {
      enable = true;
      settings = {
        server = {
          DOMAIN = cfg.forgejoDomain;
          ROOT_URL = "https://${cfg.forgejoDomain}/";
        };
        service.DISABLE_REGISTRATION = true;
        # This advertises review workflows without installing or registering a
        # runner. A runner must be isolated and receive remote-build authority.
        actions.ENABLED = cfg.reviewPipeline.enable;
      };
    };

    # A future runner reads this declarative handoff; this module never runs
    # review commands itself and therefore has no plaintext notification path.
    environment.etc."forgejo-review-pipeline/nix-review-pipeline.conf".text = ''
      check-attribute=${cfg.reviewPipeline.checkAttribute}
      command=${cfg.reviewPipeline.command}
    '';
  };
}
