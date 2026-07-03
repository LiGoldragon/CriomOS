{
  config,
  inputs,
  lib,
  pkgs,
  utils,
  horizon,
  constants,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    mkIf
    optional
    optionalAttrs
    ;
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
  wirelessCountryCode = routerInterfaces.country or routerInterfaces.wirelessCountryCode or "PL";
  wirelessNetworkName =
    routerInterfaces.ssid or routerInterfaces.wirelessNetworkName or "${cluster.name}.criome";

  backupWireless = routerInterfaces.backupWireless or null;
  hasBackupWireless = backupWireless != null;
  backupWirelessPasswordSecret = if hasBackupWireless then backupWireless.password else null;
  backupWirelessPasswordSecretName =
    if hasBackupWireless then backupWirelessPasswordSecret.name else null;
  backupWirelessSopsFileExists =
    hasBackupWireless && builtins.hasAttr backupWirelessPasswordSecretName routerWifiSopsFiles;
  backupWirelessSopsFile =
    if !hasBackupWireless then
      null
    else if backupWirelessSopsFileExists then
      routerWifiSopsFiles.${backupWirelessPasswordSecretName}
    else
      throw "router: inputs.secrets.sopsFiles.${backupWirelessPasswordSecretName} is required by horizon.node.routerInterfaces.backupWireless.password";
  backupWirelessRuntimeDirectory = "hostapd-backup-wireless";
  backupWirelessConfig = "/run/${backupWirelessRuntimeDirectory}/${backupWireless.interface}.hostapd.conf";
  backupWirelessDeviceUnit = "sys-subsystem-net-devices-${utils.escapeSystemdPath backupWireless.interface}.device";
  backupWirelessMode =
    {
      "2g" = "g";
      "5g" = "a";
      "6g" = "a";
      "60g" = "ad";
    }
    .${backupWireless.band};

  lanBridgeInterface = "br-lan";
  lanSubnetPrefix = constants.network.lan.subnetPrefix;
  lanAddress = constants.network.lan.gateway;
  lanFullAddress = "${lanAddress}/24";
  localInputInterfaces = [
    lanBridgeInterface
    routerInterfaces.wlan
    "yggTun"
  ]
  ++ optional hasBackupWireless backupWireless.interface;
  localInputInterfaceSet = concatStringsSep ", " localInputInterfaces;

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
    ]
    ++ optional hasBackupWireless {
      assertion = backupWirelessSopsFileExists;
      message = "router backup Wi-Fi secret ${backupWirelessPasswordSecretName} is missing from inputs.secrets.sopsFiles";
    };

    sops.secrets = {
      ${routerWifiPasswordSecretName} = {
        format = "binary";
        sopsFile = routerWifiSopsFile;
        mode = "0400";
        restartUnits = [ "hostapd.service" ];
      };
    }
    // optionalAttrs hasBackupWireless {
      ${backupWirelessPasswordSecretName} = {
        format = "binary";
        sopsFile = backupWirelessSopsFile;
        mode = "0400";
        restartUnits = [ "hostapd-backup-wireless.service" ];
      };
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

              # test-VM guest taps (vmt*, emitted by test-vm-host.nix only when
              # this host runs TestVm guests): admit the guests' ICMPv6 so the
              # host answers their NDP for the fe80::1 gateway and they can ping
              # the host. Scoped to vmt* — inert on a host with no guests.
              iifname "vmt*" meta l4proto ipv6-icmp accept comment "Allow NDP/ICMPv6 from test-VM guests"
              # Return traffic for connections the HOST initiates TO a guest
              # (ssh into the guest, lojix deploy-into): the guest's replies
              # arrive on its vmt* tap destined to the host, and without this the
              # default-drop input policy silently drops the SYN-ACK (host->guest
              # TCP times out). Scoped to vmt* + established/related — inert
              # without guests, and never admits unsolicited guest-to-host flows.
              iifname "vmt*" ct state { established, related } accept comment "Allow return traffic for host-initiated guest connections"

              iifname { ${localInputInterfaceSet} } accept comment "Allow local network to access the router"
              iifname "${routerInterfaces.wan}" ct state { established, related } accept comment "Allow established traffic"
              iifname "${routerInterfaces.wan}" icmp type { echo-request, destination-unreachable, time-exceeded } counter accept comment "Allow select ICMP"
              iifname "${routerInterfaces.wan}" counter drop comment "Drop all other unsolicited traffic from ${routerInterfaces.wan}"
              iifname "lo" accept comment "Accept everything from loopback interface"
            }

            chain forward {
              type filter hook forward priority filter; policy drop;

              iifname { ${lanBridgeInterface} } oifname { "${routerInterfaces.wan}" } accept comment "Allow trusted LAN to WAN"
              iifname { "${routerInterfaces.wan}" } oifname { ${lanBridgeInterface} } ct state { established, related } accept comment "Allow established back to LANs"

              # Route between this host's own test-VM guest taps (vmt*, emitted
              # by test-vm-host.nix): guest A -> host -> guest B. The guests sit
              # on point-to-point taps, so peer traffic is FORWARDED (L3) through
              # the host. Scoped to vmt*<->vmt* — inert on a host with no guests.
              iifname "vmt*" oifname "vmt*" accept comment "Allow test-VM guest<->guest forwarding"
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
    }
    // optionalAttrs hasBackupWireless {
      udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="net", KERNEL=="${backupWireless.interface}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hostapd-backup-wireless.service"
      '';
    };

    systemd.services = {
      # Router access is the recovery path during upgrades. Do not
      # automatically bounce the live network services just because their
      # unit text changed; a reboot or an explicit operator restart applies
      # changed network policy after the new generation is known-good.
      systemd-networkd.restartIfChanged = false;
      systemd-networkd.stopIfChanged = false;
      hostapd.restartIfChanged = false;
      hostapd.stopIfChanged = false;
      dnsmasq.restartIfChanged = false;
      dnsmasq.stopIfChanged = false;

      # sops-install-secrets runs as part of system activation (before any
      # service starts), so /run/secrets/routerWifiSaePasswords is already
      # in place by the time hostapd's ExecStartPre reads it. Rotation is
      # handled by `sops.secrets.<name>.restartUnits = [ "hostapd.service" ]`
      # declared above. There is no `sops-nix.service` systemd unit in
      # current sops-nix — depending on it would prevent hostapd from
      # starting and break wifi.
      kea-dhcp4-server = {
        after = [ "systemd-networkd.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
      };
    }
    // optionalAttrs hasBackupWireless {
      hostapd-backup-wireless = {
        description = "Backup Wi-Fi access point for router emergency access";
        after = [
          backupWirelessDeviceUnit
          "systemd-networkd.service"
        ];
        bindsTo = [ backupWirelessDeviceUnit ];
        wantedBy = [ backupWirelessDeviceUnit ];
        path = [
          pkgs.coreutils
          pkgs.hostapd
          pkgs.iproute2
        ];
        restartIfChanged = false;
        stopIfChanged = false;
        preStart = ''
          set -euo pipefail
          config_file=${backupWirelessConfig}
          password_file=${config.sops.secrets.${backupWirelessPasswordSecretName}.path}
          install -m 0700 -d "$(dirname "$config_file")"
          password="$(tr -d '\n' < "$password_file")"
          cat > "$config_file" <<EOF
          driver=nl80211
          interface=${backupWireless.interface}
          bridge=${lanBridgeInterface}
          ssid=${backupWireless.networkName}
          utf8_ssid=1
          country_code=${wirelessCountryCode}
          ieee80211d=1
          ieee80211h=1
          hw_mode=${backupWirelessMode}
          channel=${toString backupWireless.channel}
          ieee80211n=1
          ht_capab=[SHORT-GI-20]
          wmm_enabled=1
          auth_algs=1
          wpa=2
          wpa_key_mgmt=WPA-PSK-SHA256
          wpa_pairwise=CCMP
          rsn_pairwise=CCMP
          ieee80211w=1
          wpa_passphrase=$password
          EOF
          unset password
        '';
        serviceConfig = {
          ExecStart = "${pkgs.hostapd}/bin/hostapd ${backupWirelessConfig}";
          Restart = "always";
          RuntimeDirectory = backupWirelessRuntimeDirectory;
          RuntimeDirectoryMode = "0700";
          DeviceAllow = "/dev/rfkill rw";
          DevicePolicy = "closed";
          NoNewPrivileges = true;
          PrivateTmp = false;
          PrivateUsers = false;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
            "AF_UNIX"
            "AF_PACKET"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          UMask = "0077";
        };
      };
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

        # USB ethernet dongles are optional hotplug LAN ports: if absent,
        # boot and router networking continue; if plugged later, networkd
        # applies this match and joins the dongle to the bridge.
        "30-usb-eth" = {
          matchConfig = {
            Type = "ether";
            Driver = "cdc_ether cdc_ncm r8152 ax88179_178a asix";
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
