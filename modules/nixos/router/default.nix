{
  lib,
  horizon,
  resolveSecret,
  constants,
  ...
}:
let
  inherit (lib) mkIf last splitString;
  inherit (horizon) cluster;
  inherit (horizon.node) behavesAs;

  routerInterfaces =
    horizon.node.routerInterfaces
      or (throw "router: horizon.node.routerInterfaces is required for router nodes");

  # SecretReference for the WPA3-SAE password. Dispatch through the
  # cluster's secret-binding table — the per-cluster `secretBindings`
  # map decides which backend (Sops | SystemdCredential | Agenix)
  # stores the password; the consumer reads `runtimePath` for the
  # decrypted bytes and (when backend = Sops) `sopsConfig` for the
  # activation-time `sops.secrets.${name}` declaration.
  resolvedRouterWifiPassword = resolveSecret routerInterfaces.wpa3SaePassword;

  clusterLan =
    cluster.lan
      or (throw "router: horizon.cluster.lan is required for router nodes (subnet/gateway/DHCP come from horizon)");

  lanBridgeInterface = "br-lan";

  # Pull cluster-specific LAN addressing from horizon; keep the
  # implementation lease policy in CriomOS-lib.
  lanCidr = clusterLan.cidr; # e.g. "10.18.0.0/24"
  lanGateway = clusterLan.gateway; # e.g. "10.18.0.1"
  lanPrefixLength = last (splitString "/" lanCidr); # "24"
  lanFullAddress = "${lanGateway}/${lanPrefixLength}";

  dhcpPool = clusterLan.dhcpPool;
  dhcpPoolRange = "${dhcpPool.start} - ${dhcpPool.end}";

  leaseTtl = constants.network.lan.lease.defaultTtlSeconds;
  # RFC 2131 §4.4.5: T1 ≈ 0.5 × lease, T2 ≈ 0.875 × lease.
  # kea uses renew-timer = T1, rebind-timer = T2.
  leaseRenewTimer = leaseTtl / 2;
  leaseRebindTimer = (leaseTtl * 7) / 8;

  useNftables = true;

in
{
  imports = [
    ../secrets.nix
    ./wifi-pki.nix
    ./yggdrasil.nix
  ];

  config = mkIf behavesAs.router (lib.mkMerge [
    (lib.mkIf (resolvedRouterWifiPassword.kind == "Sops") {
      sops.secrets.${resolvedRouterWifiPassword.name} = resolvedRouterWifiPassword.sopsConfig // {
        mode = "0400";
        restartUnits = [ "hostapd.service" ];
      };
    })
    {

    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = true;
      "net.ipv6.conf.all.forwarding" = true;
    };

    networking = {
      useNetworkd = true;
      useDHCP = false;
      nat.enable = false;
      firewall.enable = !useNftables;

      nftables = {
        enable = useNftables;
        ruleset = ''
          table inet filter {
            chain input {
              type filter hook input priority 0; policy drop;

              ip6 saddr fe80::/64 ip6 daddr fe80::/64 udp dport 9001 accept
              ip6 saddr fe80::/64 ip6 daddr fe80::/64 tcp dport 10001 accept

              tcp dport ssh accept

              iifname { ${lanBridgeInterface}, ${routerInterfaces.wlan}, yggTun } accept comment "Allow local network to access the router"
              iifname "${routerInterfaces.wan}" ct state { established, related } accept comment "Allow established traffic"
              iifname "${routerInterfaces.wan}" icmp type { echo-request, destination-unreachable, time-exceeded } counter accept comment "Allow select ICMP"
              iifname "${routerInterfaces.wan}" counter drop comment "Drop all other unsolicited traffic from ${routerInterfaces.wan}"
              iifname "lo" accept comment "Accept everything from loopback interface"
            }

            chain forward {
              type filter hook forward priority filter; policy drop;

              iifname { ${lanBridgeInterface} } oifname { "${routerInterfaces.wan}" } accept comment "Allow trusted LAN to WAN"
              iifname { "${routerInterfaces.wan}" } oifname { ${lanBridgeInterface} } ct state { established, related } accept comment "Allow established back to LANs"
            }
          }

          table ip nat {
            chain postrouting {
              type nat hook postrouting priority 100; policy accept;
              oifname "${routerInterfaces.wan}" masquerade
            }
          }
        '';
      };
    };

    services = {
      hostapd = {
        enable = true;
        radios = {
          "${routerInterfaces.wlan}" = {
            band = routerInterfaces.wlanBand;
            channel = routerInterfaces.wlanChannel;
            countryCode = routerInterfaces.country;
            wifi4.enable = routerInterfaces.wlanStandard == "wifi4";
            wifi6.enable = routerInterfaces.wlanStandard == "wifi6" || routerInterfaces.wlanStandard == "wifi7";
            wifi7.enable = routerInterfaces.wlanStandard == "wifi7";
            networks = {
              "${routerInterfaces.wlan}" = {
                ssid = routerInterfaces.ssid;
                authentication = {
                  mode = "wpa3-sae";
                  saePasswordsFile = resolvedRouterWifiPassword.runtimePath;
                };
                settings = {
                  bridge = lanBridgeInterface;
                };
              };
            };
          };
        };
      };

      kea = {
        dhcp4 = {
          enable = true;
          settings = {
            valid-lifetime = leaseTtl;
            renew-timer = leaseRenewTimer;
            rebind-timer = leaseRebindTimer;
            interfaces-config = {
              interfaces = [ lanBridgeInterface ];
              dhcp-socket-type = "raw";
            };
            lease-database = {
              type = "memfile";
              persist = true;
              name = "/var/lib/kea/dhcp4.leases";
            };
            subnet4 = [
              {
                id = 1;
                subnet = lanCidr;
                pools = [ { pool = dhcpPoolRange; } ];
                option-data = [
                  {
                    name = "routers";
                    data = lanGateway;
                  }
                  {
                    name = "domain-name-servers";
                    data = lanGateway;
                  }
                ];
              }
            ];
          };
        };
      };
    };

    systemd.services.kea-dhcp4-server.after = [ "systemd-networkd.service" ];

    systemd.network = {
      enable = true;
      wait-online.anyInterface = true;

      netdevs = {
        "20-br-lan" = {
          netdevConfig = {
            Kind = "bridge";
            Name = lanBridgeInterface;
          };
        };
      };

      networks = {
        "10-wan" = {
          matchConfig.Name = routerInterfaces.wan;
          networkConfig = {
            DHCP = "ipv4";
            KeepConfiguration = "dynamic-on-stop";
          };
          dhcpV4Config = {
            SendRelease = false;
          };
          linkConfig.RequiredForOnline = "routable";
        };

        # Any USB ethernet dongle auto-bridges to the LAN
        "30-usb-eth" = {
          matchConfig = {
            Type = "ether";
            Driver = "cdc_ether r8152 ax88179_178a asix";
          };
          networkConfig = {
            Bridge = lanBridgeInterface;
            ConfigureWithoutCarrier = true;
          };
          linkConfig.RequiredForOnline = "no";
        };

        "40-br-lan" = {
          matchConfig.Name = lanBridgeInterface;
          bridgeConfig = { };
          address = [ lanFullAddress ];
          networkConfig = {
            ConfigureWithoutCarrier = true;
          };
        };
      };
    };

    }
  ]);
}
