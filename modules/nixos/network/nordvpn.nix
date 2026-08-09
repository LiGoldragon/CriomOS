{
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (builtins) fromJSON readFile;
  inherit (lib) mkIf concatStringsSep map;
  inherit (constants.fileSystem.nordvpn) privateKeyFile;

  hasNordvpnPubKey = horizon.node.hasNordvpnPubKey or (horizon.node.nordvpn or false);

  /*
    Server data is read from the lock file at build time.
    Update with: nix shell nixpkgs#curl nixpkgs#jq -c ./data/config/nordvpn/update-servers
  */
  lockPath = ../../../data/config/nordvpn/servers-lock.json;
  lock = fromJSON (readFile lockPath);

  nordvpnDns = "${lock.dns.primary};${lock.dns.secondary}";
  clientAddress = lock.client.address;

  mkConnectionFile = server: ''
    cat > "/etc/NetworkManager/system-connections/nordvpn-${server.name}.nmconnection" <<CONN
    [connection]
    id=nordvpn-${server.name}
    type=wireguard
    interface-name=nv-${server.name}
    autoconnect=false

    [wireguard]
    private-key=$NORDVPN_KEY
    # NetworkManager's native improved rule-based routing is the equivalent
    # of wg-quick Table=auto. It installs the fwmark, dedicated table, and
    # rules as one connection transaction, including endpoint escape.
    fwmark=51820
    ip4-auto-default-route=true
    ip6-auto-default-route=false
    peer-routes=true

    [wireguard-peer.${server.publicKey}]
    endpoint=${server.endpoint}
    allowed-ips=0.0.0.0/0;
    persistent-keepalive=25;

    [ipv4]
    method=manual
    address1=${clientAddress}
    dns=${nordvpnDns}
    dns-search=~.;
    dns-priority=-50
    ignore-auto-dns=true
    never-default=false

    [ipv6]
    method=disabled
    CONN
    chmod 600 "/etc/NetworkManager/system-connections/nordvpn-${server.name}.nmconnection"
  '';

  generatorScript = concatStringsSep "\n" ([
    ''
      NORDVPN_KEY=$(cat "${privateKeyFile}" 2>/dev/null | tr -d '[:space:]')
      if [ -z "$NORDVPN_KEY" ]; then
        echo "nordvpn: private key not found at ${privateKeyFile}" >&2
        exit 0
      fi
      umask 077
    ''
  ] ++ (map mkConnectionFile lock.servers) ++ [
    ''
      if systemctl is-active --quiet NetworkManager.service; then
        nmcli connection reload
      fi
    ''
  ]);

  privateKeyDir = builtins.dirOf privateKeyFile;

in
{
  config = lib.mkMerge [
    (mkIf hasNordvpnPubKey {
      systemd.services.nordvpn-connections = {
        description = "Generate NordVPN NetworkManager connections";
        wantedBy = [ "NetworkManager.service" ];
        before = [ "NetworkManager.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        restartTriggers = [ lockPath ];
        script = generatorScript;
      };
    })

    (mkIf (!hasNordvpnPubKey) {
      /*
        When nordvpn is not yet enabled, prepare the key directory
        so operators can seed the private key. The directory is
        temporarily world-writable; the nordvpn-seal service locks
        it down to root:root 700 on the next boot after seeding.
        Once the key is in place, set nordvpn = true in the node
        proposal and rebuild.
      */
      systemd.services.nordvpn-prepare = {
        description = "Prepare NordVPN private key directory for seeding";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p "${privateKeyDir}"
          if [ -f "${privateKeyFile}" ]; then
            chmod 600 "${privateKeyFile}"
            chmod 700 "${privateKeyDir}"
            chown -R root:root "${privateKeyDir}"
          else
            chmod 700 "${privateKeyDir}"
            chown root:root "${privateKeyDir}"
            echo "nordvpn: private key not found at ${privateKeyFile}" >&2
            echo "nordvpn: seed as root: echo '<key>' > ${privateKeyFile}" >&2
          fi
        '';
      };
    })
  ];
}
