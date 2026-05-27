{
  config,
  inputs,
  lib,
  horizon,
  constants,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon) cluster;
  inherit (horizon.node) behavesAs;
  # WiFi PKI paths — uncomment when EAP-TLS is deployed
  # inherit (constants.fileSystem.wifiPki) caCertFile serverCertFile serverKeyFile;

  routerInterfaces =
    horizon.node.routerInterfaces
      or (throw "router: horizon.node.routerInterfaces is required for router nodes");
  routerWifiPasswordSecret =
    routerInterfaces.wpa3SaePassword
      or (throw "router: horizon.node.routerInterfaces.wpa3SaePassword is required for WPA3-SAE");
  routerWifiPasswordSecretName = routerWifiPasswordSecret.name;
  routerWifiSopsFiles = inputs.secrets.sopsFiles or { };
  routerWifiSopsFileExists = builtins.hasAttr routerWifiPasswordSecretName routerWifiSopsFiles;
  routerWifiSopsFile =
    if routerWifiSopsFileExists then
      routerWifiSopsFiles.${routerWifiPasswordSecretName}
    else
      throw "router: inputs.secrets.sopsFiles.${routerWifiPasswordSecretName} is required by horizon.node.routerInterfaces.wpa3SaePassword";
  wirelessCountryCode =
    routerInterfaces.country or routerInterfaces.wirelessCountryCode or "PL";
  wirelessNetworkName =
    routerInterfaces.ssid or routerInterfaces.wirelessNetworkName or "${cluster.name}.criome";

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
    assertions = [
      {
        assertion = routerWifiSopsFileExists;
        message = "router Wi-Fi secret ${routerWifiPasswordSecretName} is missing from inputs.secrets.sopsFiles";
      }
    ];

    sops.secrets.${routerWifiPasswordSecretName} = {
      format = "binary";
      sopsFile = routerWifiSopsFile;
      mode = "0400";
      restartUnits = [ "hostapd.service" ];
    };

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
            countryCode = wirelessCountryCode;
            wifi4.enable = routerInterfaces.wlanStandard == "wifi4";
            wifi6.enable = routerInterfaces.wlanStandard == "wifi6" || routerInterfaces.wlanStandard == "wifi7";
            wifi7.enable = routerInterfaces.wlanStandard == "wifi7";
            networks = {
              # WPA3-SAE — primary SSID (EAP-TLS will replace this once PKI is deployed)
              "${routerInterfaces.wlan}" = {
                ssid = wirelessNetworkName;
                authentication = {
                  mode = "wpa3-sae";
                  saePasswordsFile = config.sops.secrets.${routerWifiPasswordSecretName}.path;
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

    systemd.services = {
      # sops-install-secrets runs as part of system activation (before any
      # service starts), so /run/secrets/routerWifiSaePasswords is already
      # in place by the time hostapd's ExecStartPre reads it. Rotation is
      # handled by `sops.secrets.<name>.restartUnits = [ "hostapd.service" ]`
      # declared above. There is no `sops-nix.service` systemd unit in
      # current sops-nix — depending on it would prevent hostapd from
      # starting and break wifi.
      kea-dhcp4-server.after = [ "systemd-networkd.service" ];
    };

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

  };
}
