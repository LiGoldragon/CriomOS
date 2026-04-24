{
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;
  inherit (horizon.node.machine) model;
  # WiFi PKI paths — uncomment when EAP-TLS is deployed
  # inherit (constants.fileSystem.wifiPki) caCertFile serverCertFile serverKeyFile;

  # Per-model interface mapping
  interfaceMap = {
    # asklepios (old router)
    "all-x86-64" = {
      wan = "enp0s25";
      wlan = "wlp3s0";
      wlanBand = "2g";
      wlanChannel = 1;
      wlanStandard = "wifi4";
    };
    # Prometheus (GMKtec EVO-X2, WiFi 7 hardware)
    # 6GHz AP mode fails ACS — firmware/regulatory limitation.
    # Fall back to 2.4GHz for maximum client compatibility.
    "GMKtec EVO-X2" = {
      wan = "eno1";
      wlan = "wlp195s0";
      wlanBand = "2g";
      wlanChannel = 6;
      wlanStandard = "wifi4";
    };
  };

  hw = interfaceMap.${model} or (throw "router: no interface map for model ${model}");

  lanBridgeInterface = "br-lan";
  lanSubnetPrefix = constants.network.lan.subnetPrefix;
  lanAddress = constants.network.lan.gateway;
  lanFullAddress = "${lanAddress}/24";

  useNftables = true;

in
{
  imports = [
    ./wifi-pki.nix
    ./yggdrasil.nix
  ];

  config = mkIf behavesAs.router {

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

            iifname { ${lanBridgeInterface}, ${hw.wlan}, yggTun } accept comment "Allow local network to access the router"
            iifname "${hw.wan}" ct state { established, related } accept comment "Allow established traffic"
            iifname "${hw.wan}" icmp type { echo-request, destination-unreachable, time-exceeded } counter accept comment "Allow select ICMP"
            iifname "${hw.wan}" counter drop comment "Drop all other unsolicited traffic from ${hw.wan}"
            iifname "lo" accept comment "Accept everything from loopback interface"
          }

          chain forward {
            type filter hook forward priority filter; policy drop;

            iifname { ${lanBridgeInterface} } oifname { "${hw.wan}" } accept comment "Allow trusted LAN to WAN"
            iifname { "${hw.wan}" } oifname { ${lanBridgeInterface} } ct state { established, related } accept comment "Allow established back to LANs"
          }
        }

        table ip nat {
          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
            oifname "${hw.wan}" masquerade
          }
        }
      '';
    };
  };

  services = {
    hostapd = {
      enable = true;
      radios = {
        "${hw.wlan}" = {
          band = hw.wlanBand;
          channel = hw.wlanChannel;
          countryCode = "PL";
          wifi4.enable = hw.wlanStandard == "wifi4";
          wifi6.enable = hw.wlanStandard == "wifi6" || hw.wlanStandard == "wifi7";
          wifi7.enable = hw.wlanStandard == "wifi7";
          networks = {
            # WPA3-SAE — primary SSID (EAP-TLS will replace this once PKI is deployed)
            "${hw.wlan}" = {
              ssid = "criome";
              authentication = {
                mode = "wpa3-sae";
                saePasswords = [ { password = "leavesarealsoalive"; } ];
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
          valid-lifetime = 4000;
          renew-timer = 1000;
          rebind-timer = 2000;
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
              subnet = lanFullAddress;
              pools = [ { pool = "${lanSubnetPrefix}.100 - ${lanSubnetPrefix}.240"; } ];
              option-data = [
                {
                  name = "routers";
                  data = lanAddress;
                }
                {
                  name = "domain-name-servers";
                  data = lanAddress;
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
        matchConfig.Name = hw.wan;
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

  };
}
