{
  config,
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  inherit (builtins) toString;
  inherit (horizon) cluster node;

  headscaleFqdn = node.criomeDomainName;
  nodeServices = import ../node-services.nix { inherit lib; };
  services = node.services or [ ];
  isTailnetController = nodeServices.has services "TailnetController";
  headscalePort = constants.network.headscale.port;

  # The controller role is a variant. Base domain is per-cluster and
  # service port is a CriomOS-lib constant, never cluster-authored.
  # Every node hosting a controller requires `cluster.tailnet` to be
  # present (validated at horizon projection time via
  # `Error::TailnetControllerWithoutClusterConfig`); inside the
  # `mkIf isTailnetController` block below it is safe
  # to assume non-null.
  clusterTailnet =
    if !isTailnetController then
      null
    else
      cluster.tailnet
        or (throw "headscale: cluster.tailnet must be set when a node hosts a tailnet controller (validated by horizon projection — TailnetControllerWithoutClusterConfig)");
  tailnetBaseDomain = if clusterTailnet == null then null else clusterTailnet.baseDomain;

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

    # Self-signed cert when cluster.tailnet.tls is absent. Once the
    # operator authors a CA + server cert in horizon, this script
    # becomes a no-op (certs already on disk).
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
  config = lib.mkIf isTailnetController {
    services.headscale = {
      enable = true;
      address = "0.0.0.0";
      port = headscalePort;

      # Direct TLS (no reverse proxy) for Phase 1.
      settings = {
        server_url = "https://${headscaleFqdn}:${toString headscalePort}";

        tls_cert_path = tlsCertPath;
        tls_key_path = tlsKeyPath;

        # base_domain comes from horizon.cluster.tailnet.baseDomain.
        dns = {
          magic_dns = true;
          base_domain = tailnetBaseDomain;
          override_local_dns = false;
        };
      };
    };

    systemd.services.headscale-selfsigned-cert = {
      description = "Generate headscale self-signed TLS certificate when cluster.tailnet.tls is absent";
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
