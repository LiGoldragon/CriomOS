{
  lib,
  pkgs,
  horizon,
  resolveSecret,
  ...
}:
let
  inherit (lib) mkIf concatStringsSep filter map;
  inherit (horizon) node;
  # Step 7b: gate on the underlying input bool directly (was hasNordvpnPubKey).
  hasNordvpnPubKey = horizon.node.nordvpn;

  # Step 8: VPN catalog comes from horizon.cluster.vpnProfiles. The
  # previous data/config/nordvpn/servers-lock.json shadow file is
  # deleted; the cluster's datom now carries every server entry,
  # DNS pair, and client config that used to live in JSON.
  vpnProfiles = horizon.cluster.vpnProfiles or [ ];
  nordvpnProfiles = filter (p: p ? NordvpnProfile) vpnProfiles;
  nordvpnProfile =
    if nordvpnProfiles == [ ] then null
    else if builtins.length nordvpnProfiles > 1 then
      throw "nordvpn.nix: more than one NordvpnProfile in cluster.vpnProfiles; only one is supported"
    else (builtins.head nordvpnProfiles).NordvpnProfile;

  servers = if nordvpnProfile == null then [ ] else nordvpnProfile.servers;
  nordvpnDns =
    if nordvpnProfile == null then ""
    else "${nordvpnProfile.dns.primary};${nordvpnProfile.dns.secondary}";
  clientAddress =
    if nordvpnProfile == null then "" else nordvpnProfile.client.address;

  # SecretReference for the WireGuard private key. Dispatch through
  # the cluster's secret-binding table — `resolveSecret` looks up
  # `nordvpnProfile.credentials.name` in `horizon.cluster.secretBindings`
  # and returns the resolved-backend record (today: Sops; tomorrow:
  # SystemdCredential / Agenix). The consumer reads `runtimePath` for
  # the decrypted value and `sopsConfig` for the activation-time
  # `sops.secrets.${name}` declaration.
  credentialsRef =
    if nordvpnProfile == null then null else nordvpnProfile.credentials;
  resolvedCredentials =
    if credentialsRef == null then null else resolveSecret credentialsRef;
  privateKeyFile =
    if resolvedCredentials == null then null else resolvedCredentials.runtimePath;

  routingTable = "51820";

  # Server endpoint IPs extracted from horizon. These must be routed
  # via the main table to prevent a routing loop — encrypted WireGuard
  # packets to the server must not re-enter the tunnel.
  serverEndpointIps = map (s: builtins.head (lib.splitString ":" s.endpoint)) servers;

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

  # Loud-fail when this node opts in (nordvpn=true) but the cluster
  # has no NordvpnProfile. The secret-binding side fails inside
  # resolveSecret (binding-missing or staged-file-missing); the
  # profile-missing case stays local because resolveSecret has no
  # opinion about whether a profile exists at all.
  enabledWithoutProfile = hasNordvpnPubKey && nordvpnProfile == null;
  generatorScript =
    if enabledWithoutProfile then
      throw "nordvpn.nix: node ${node.name}.nordvpn = true but cluster.vpnProfiles has no NordvpnProfile"
    else
      concatStringsSep "\n" ([
        ''
          NORDVPN_KEY=$(cat "${privateKeyFile}" 2>/dev/null | tr -d '[:space:]')
          if [ -z "$NORDVPN_KEY" ]; then
            echo "nordvpn: private key not present at ${privateKeyFile} (sops-install-secrets must have failed)" >&2
            exit 0
          fi
        ''
      ] ++ (map mkConnectionFile servers) ++ [
        ''
          nmcli connection reload 2>/dev/null || true
        ''
      ]);

  # NetworkManager dispatcher script for split-tunnel policy routing.
  # On connection up: installs default route in table 51820 and adds
  # ip rules that steer user traffic through the tunnel while exempting
  # overlay networks (Yggdrasil, Tailscale, WireGuard mesh).
  # Priority: 100 = server endpoints (exempt), 150 = Tailscale (exempt),
  # 200 = catch-all into tunnel. Yggdrasil 200::/7 is IPv6 — naturally
  # exempt from the IPv4-only tunnel.
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

in
{
  # sops options come from ../secrets.nix; declare the dependency
  # locally so isolated module tests (cluster-contracts loads only
  # network + router, not the criomos aggregate) still resolve the
  # `sops.secrets.<name>` references below.
  imports = [ ../secrets.nix ];

  config = mkIf hasNordvpnPubKey (lib.mkMerge [
    (lib.mkIf (resolvedCredentials != null && resolvedCredentials.kind == "Sops") {
      sops.secrets.${resolvedCredentials.name} = resolvedCredentials.sopsConfig // {
        mode = "0400";
        restartUnits = [ "nordvpn-connections.service" ];
      };
    })
    {
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
    }
  ]);
}
