{
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node.methods) behavesAs;
  inherit (constants.fileSystem.wifiPki) serverDir serverKeyFile;

  serverKeyDir = serverDir;

in
{
  config = lib.mkMerge [
    (mkIf behavesAs.router {
      systemd.services.wifi-pki-server = {
        description = "Provision WiFi PKI server key directory";
        wantedBy = [ "hostapd.service" ];
        before = [ "hostapd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p "${serverKeyDir}"
          if [ -f "${serverKeyFile}" ]; then
            chmod 600 "${serverKeyFile}"
            chmod 700 "${serverKeyDir}"
            chown -R root:root "${serverKeyDir}"
          else
            echo "wifi-pki: server key not found at ${serverKeyFile}" >&2
            echo "wifi-pki: generate with: clavifaber server-cert --ca-keygrip <kg> --ca-cert ca.pem --cn <host>.criome --out-cert server.pem --out-key server.key" >&2
            echo "wifi-pki: then scp server.key root@<router>:${serverKeyFile}" >&2
            chmod 700 "${serverKeyDir}"
            chown root:root "${serverKeyDir}"
          fi
        '';
      };
    })
  ];
}
