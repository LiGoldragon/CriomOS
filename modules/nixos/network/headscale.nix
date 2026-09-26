{
  config,
  lib,
  pkgs,
  horizon,
  constants,
  inputs,
  ...
}:
let
  inherit (builtins) toString;
  inherit (horizon) node;

  tailnet = import ./tailnet-roles.nix {
    inherit
      lib
      pkgs
      horizon
      constants
      ;
  };

  headscaleFqdn = node.criomeDomainName;
  headscalePort = tailnet.controlPort;
  headscaleUser = config.services.headscale.user;
  headscaleGroup = config.services.headscale.group;

  tlsCertificatePath = config.sops.secrets.${tailnet.tlsCertificateSecret}.path;
  tlsKeyPath = config.sops.secrets.${tailnet.tlsKeySecret}.path;

  # Refuse to serve a certificate that the cluster CA did not issue or that
  # does not name this node's current domain. A renamed cluster or a stale
  # certificate stops Headscale with a reason instead of serving a name no
  # client can verify.
  verifyServerCertificate = pkgs.writeShellScript "headscale-verify-server-certificate" ''
    set -euo pipefail
    ${lib.getExe pkgs.openssl} verify \
      -CAfile ${tailnet.certificateAuthorityFile} \
      -purpose sslserver \
      ${tlsCertificatePath}
    ${lib.getExe pkgs.openssl} x509 -noout -in ${tlsCertificatePath} \
      -checkhost ${lib.escapeShellArg headscaleFqdn} \
      | ${lib.getExe' pkgs.gnugrep "grep"} -F ' does match certificate'
  '';
in
{
  config = lib.mkIf tailnet.isController {
    sops.secrets = {
      ${tailnet.tlsCertificateSecret} = tailnet.sopsSecret inputs "TailnetController" tailnet.tlsCertificateSecret {
        owner = headscaleUser;
        group = headscaleGroup;
        mode = "0400";
        restartUnits = [ "headscale.service" ];
      };
      ${tailnet.tlsKeySecret} = tailnet.sopsSecret inputs "TailnetController" tailnet.tlsKeySecret {
        owner = headscaleUser;
        group = headscaleGroup;
        mode = "0400";
        restartUnits = [ "headscale.service" ];
      };
    };

    services.headscale = {
      enable = true;
      address = "0.0.0.0";
      port = headscalePort;

      # Direct TLS (no reverse proxy). The certificate and key are sops
      # secrets named by the TailnetController capability; the cluster CA
      # that issued them is in every tailnet node's trust store.
      settings = {
        server_url = "https://${headscaleFqdn}:${toString headscalePort}";

        tls_cert_path = tlsCertificatePath;
        tls_key_path = tlsKeyPath;

        # Must differ from server_url domain.
        dns = {
          magic_dns = true;
          base_domain = horizon.tailnetBaseDomain;
          override_local_dns = false;
        };
      };
    };

    systemd.services.headscale.serviceConfig.ExecStartPre = [ verifyServerCertificate ];

    networking.firewall.allowedTCPPorts = [ headscalePort ];
  };
}
