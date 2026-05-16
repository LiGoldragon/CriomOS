{
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon) node cluster;
  # Step 7b: gate on the underlying input bool directly (was hasWifiCertPubKey).
  hasWifiCertPubKey = horizon.node.wifiCert;
  inherit (constants.fileSystem.wifiPki) caCertFile certsDir;
  inherit (constants.fileSystem.complex) keyFile;

  nodeCertFile = "${certsDir}/${node.name}.pem";

  # The EAP-TLS client connects to the cluster's broadcast SSID; the
  # router-side hostapd config uses `routerInterfaces.ssid` per-node,
  # but at the client side we read `cluster.domain` — the single
  # cluster-wide identifier ("criome" today) that both halves resolve
  # against. NetworkManager `id=` matches `ssid=` so both render from
  # the same source.
  clusterSsid = cluster.domain;

  # NM connection: WPA3-Enterprise EAP-TLS using the complex's private key.
  # autoconnect-priority=100 prefers this over any other WiFi network.
  nmConnection = ''
    [connection]
    id=${clusterSsid}
    type=wifi
    autoconnect=true
    autoconnect-priority=100

    [wifi]
    ssid=${clusterSsid}
    mode=infrastructure

    [wifi-security]
    key-mgmt=wpa-eap

    [802-1x]
    eap=tls;
    identity=${node.name}
    ca-cert=${caCertFile}
    client-cert=${nodeCertFile}
    private-key=${keyFile}
    private-key-password-flags=not-required

    [ipv4]
    method=auto

    [ipv6]
    method=auto
  '';

in
{
  config = lib.mkMerge [
    (mkIf hasWifiCertPubKey {
      systemd.services.wifi-eap-connection = {
        description = "Deploy WiFi EAP-TLS connection (criome)";
        wantedBy = [ "NetworkManager.service" ];
        before = [ "NetworkManager.service" ];
        after = [ "complex-init.service" ];
        requires = [ "complex-init.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p "${certsDir}"

          if [ ! -f "${keyFile}" ]; then
            echo "wifi-eap: complex not initialized, skipping" >&2
            exit 0
          fi

          if [ ! -f "${nodeCertFile}" ]; then
            echo "wifi-eap: node certificate not found at ${nodeCertFile}" >&2
            echo "wifi-eap: sign with: clavifaber node-cert --ca-keygrip <kg> --ca-cert ca.pem --ssh-pubkey \"\$(cat /etc/criomOS/complex/ssh.pub)\" --cn ${node.name} --out ${node.name}.pem" >&2
            exit 0
          fi

          cat > "/etc/NetworkManager/system-connections/criome.nmconnection" <<'CONN'
          ${nmConnection}
          CONN
          chmod 600 "/etc/NetworkManager/system-connections/criome.nmconnection"

          nmcli connection reload 2>/dev/null || true
        '';
      };
    })

    (mkIf (!hasWifiCertPubKey) {
      systemd.services.wifi-eap-prepare = {
        description = "Prepare WiFi PKI certificate directory";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p "${certsDir}"
          chmod 755 "${certsDir}"
        '';
      };
    })
  ];
}
