{
  config,
  horizon,
  inputs,
  lib,
  ...
}:

# Deployment consumer for the one approved Goldragon target. The provider
# module stays generic and disabled by default; this adapter is the explicit
# target composition that Lojix evaluates from the projected Horizon.
let
  isPrometheusTarget =
    (horizon.cluster or null) == "goldragon"
    && (horizon.node.name or null) == "prometheus";
  secretsFiles = inputs.secrets.sopsFiles or { };
  hasAccountSecrets =
    builtins.hasAttr "prosodyLiPassword" secretsFiles
    && builtins.hasAttr "prosodyPersonaPassword" secretsFiles;
in
lib.mkIf isPrometheusTarget {
  assertions = [
    {
      assertion = hasAccountSecrets;
      message = "Goldragon Prometheus Prosody consumer requires inputs.secrets.sopsFiles prosodyLiPassword and prosodyPersonaPassword";
    }
  ];

  criomos.prometheusServiceProvider = {
    enable = true;
    xmppDomain = "xmpp.goldragon.criome.net";
    xmppDomainAliases = [ "xmpp.goldragon.criome" ];
    forgejo.enable = false;
    tls.generateSelfSigned = true;
  };

  # These declarations carry opaque SOPS ciphertext to the target's
  # root-owned runtime paths. The root-owned one-time account lifecycle reads
  # them after a distinct existing-account guard; this consumer never invokes
  # prosodyctl and never exposes a credential to an agent.
  sops.secrets = lib.mkIf hasAccountSecrets {
    "prosody-li-password" = {
      sopsFile = secretsFiles.prosodyLiPassword;
      format = "binary";
      key = "";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    "prosody-persona-password" = {
      sopsFile = secretsFiles.prosodyPersonaPassword;
      format = "binary";
      key = "";
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };
}
