{
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  inherit (builtins) fromJSON readFile pathExists;
  inherit (lib) mkIf concatStringsSep map;
  inherit (horizon) node;
  inherit (horizon.node.methods) hasNordvpnPrecriad;
  inherit (constants.fileSystem.nordvpn) privateKeyFile;

  /*
    Server data is read from the lock file at build time.
    Update with: nix shell nixpkgs#curl nixpkgs#jq -c ./data/config/nordvpn/update-servers
  */
  lockPath = ../../../data/config/nordvpn/servers-lock.json;
  lock = fromJSON (readFile lockPath);

  nordvpnDns = "${lock.dns.primary};${lock.dns.secondary}";
  clientAddress = lock.client.address;

  routingTable = "51820";

  /*
    Server endpoint IPs extracted at build time.
    These must be routed via the main table to prevent a routing
    loop — encrypted WireGuard packets to the server must not
    re-enter the tunnel.
  */
  serverEndpointIps = map (s: builtins.head (lib.splitString ":" s.endpoint)) lock.servers;

  mkConnectionFile = server: ''
    cat > "/etc/NetworkManager/system-connections/nordvpn-${server.name}.nmconnection" <<CONN
    [connection]
    id=nordvpn-${server.name}
    type=wireguard
    interface-name=nv-${server.name}
    autoconnect=false

    [wireguard]
    private-key=$NORDVPN_KEY

    [wireguard-peer.${server.publicKey}]
    endpoint=${server.endpoint}
    allowed-ips=0.0.0.0/0;::/0;

    [ipv4]
    method=manual
    address1=${clientAddress}
    dns=${nordvpnDns}
    never-default=true
    route-table=${routingTable}

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
    ''
  ] ++ (map mkConnectionFile lock.servers) ++ [
    ''
      nmcli connection reload 2>/dev/null || true
    ''
  ]);

  /*
    NetworkManager dispatcher script for split-tunnel policy routing.
    On connection up: installs default route in table 51820 and adds
    ip rules that steer user traffic through the tunnel while exempting
    overlay networks (Yggdrasil, Tailscale, WireGuard mesh).
    On connection down: cleans up the rules.
  */
  /*
    Exempt server endpoints, Tailscale, then catch-all into tunnel.
    Priority numbering: 100 = server endpoints, 150 = Tailscale, 200 = tunnel.
    Yggdrasil (200::/7) is IPv6 — naturally exempt from the IPv4-only tunnel.
  */
  serverExemptRules = lib.concatMapStringsSep "\n" (ip:
    "    ip rule add to ${ip}/32 priority 100 lookup main 2>/dev/null"
  ) serverEndpointIps;

  serverCleanupRules = lib.concatMapStringsSep "\n" (ip:
    "    ip rule del to ${ip}/32 priority 100 lookup main 2>/dev/null"
  ) serverEndpointIps;

  dispatcherScript = pkgs.writeShellScript "nordvpn-split-tunnel" ''
    INTERFACE="$1"
    ACTION="$2"

    case "$INTERFACE" in
      nv-*) ;;
      *) exit 0 ;;
    esac

    TABLE=${routingTable}

    case "$ACTION" in
      up)
        ip route add default dev "$INTERFACE" table "$TABLE" 2>/dev/null

        # Exempt NordVPN server endpoints — prevents routing loop
${serverExemptRules}

        # Tailscale uses 100.64.0.0/10
        ip rule add to 100.64.0.0/10 priority 150 lookup main 2>/dev/null

        # Steer all remaining IPv4 traffic into the tunnel
        ip rule add priority 200 table "$TABLE" 2>/dev/null
        ;;
      down)
        ip route del default dev "$INTERFACE" table "$TABLE" 2>/dev/null
${serverCleanupRules}
        ip rule del priority 150 2>/dev/null
        ip rule del priority 200 2>/dev/null
        ;;
    esac
  '';

  privateKeyDir = builtins.dirOf privateKeyFile;

in
{
  config = lib.mkMerge [
    (mkIf hasNordvpnPrecriad {
      systemd.services.nordvpn-connections = {
        description = "Generate NordVPN NetworkManager connections";
        wantedBy = [ "NetworkManager.service" ];
        before = [ "NetworkManager.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = generatorScript;
      };

      networking.networkmanager.dispatcherScripts = [
        {
          source = dispatcherScript;
        }
      ];
    })

    (mkIf (!hasNordvpnPrecriad) {
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
