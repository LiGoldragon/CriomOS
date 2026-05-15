{
  config,
  lib,
  pkgs,
  horizon,
  ...
}:
let
  inherit (builtins) toString;
  inherit (horizon) cluster node;

  headscaleFqdn = node.criomeDomainName;
  services = node.services or { };
  tailnetControllerRole = services.tailnetController or null;
  tailnetControllerServer =
    if tailnetControllerRole == null then null else tailnetControllerRole.Server or null;

  headscalePort = if tailnetControllerServer == null then null else tailnetControllerServer.port;
  tailnetBaseDomain =
    if tailnetControllerServer == null then
      null
    else
      tailnetControllerServer.baseDomain or (cluster.tailnet.baseDomain or null);

  tlsDir = "/var/lib/headscale/tls";
  tlsCertPath = "${tlsDir}/headscale.crt";
  tlsKeyPath = "${tlsDir}/headscale.key";

  mkCertScript = ''
    set -euo pipefail

    certDir=${lib.escapeShellArg tlsDir}
    certFile=${lib.escapeShellArg tlsCertPath}
    keyFile=${lib.escapeShellArg tlsKeyPath}
    fqdn=${lib.escapeShellArg headscaleFqdn}
    primaryIpv4="$(
      ${lib.getExe' pkgs.iproute2 "ip"} -4 route get 1.1.1.1 2>/dev/null \
        | ${lib.getExe' pkgs.gawk "awk"} '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit }}' \
        || true
    )"

    umask 077
    mkdir -p "$certDir"

    # Allow headscale (group) to traverse the TLS directory.
    hsGroup=${lib.escapeShellArg config.services.headscale.group}
    chown root:"$hsGroup" "$certDir"
    chmod 0750 "$certDir"

    if [ -s "$certFile" ] && [ -s "$keyFile" ]; then
      exit 0
    fi

    sanList="DNS:$fqdn,DNS:localhost,IP:127.0.0.1"
    if [ -n "$primaryIpv4" ]; then
      sanList="$sanList,IP:$primaryIpv4"
    fi

    # Self-signed cert for Phase 1; will be replaced with real PKI later.
    ${lib.getExe pkgs.openssl} req \
      -x509 -newkey rsa:4096 -nodes \
      -keyout "$keyFile" \
      -out "$certFile" \
      -sha256 -days 3650 \
      -subj "/CN=$fqdn" \
      -addext "subjectAltName=$sanList"

    chown root:"$hsGroup" "$certFile" "$keyFile"
    chmod 0644 "$certFile"
    chmod 0640 "$keyFile"
  '';

in
{
  config = lib.mkIf (tailnetControllerServer != null) {
    services.headscale = {
      enable = true;
      address = "0.0.0.0";
      port = headscalePort;

      # Direct TLS (no reverse proxy) for Phase 1.
      settings = {
        server_url = "https://${headscaleFqdn}:${toString headscalePort}";

        tls_cert_path = tlsCertPath;
        tls_key_path = tlsKeyPath;

        # Must differ from server_url domain.
        dns = {
          magic_dns = true;
          base_domain = tailnetBaseDomain;
          override_local_dns = false;
        };
      };
    };

    systemd.services.headscale-selfsigned-cert = {
      description = "Generate headscale self-signed TLS certificate (Phase 1)";
      before = [ "headscale.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };

      # Ensure required binaries are in PATH for the script.
      path = [
        pkgs.coreutils
        pkgs.openssl
        pkgs.iproute2
        pkgs.gawk
      ];

      script = mkCertScript;
    };

    # Ensure the certificate exists before starting headscale.
    systemd.services.headscale = {
      requires = [ "headscale-selfsigned-cert.service" ];
      after = [ "headscale-selfsigned-cert.service" ];
    };

    networking.firewall.allowedTCPPorts = [ headscalePort ];
  };
}
