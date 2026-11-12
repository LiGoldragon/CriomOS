{
  config,
  horizon,
  lib,
  pkgs,
  ...
}:
let
  localUsers = builtins.filter (user: user.hasPublicKey) horizon.users;
  startUserDrains = lib.concatMapStringsSep "\n" (user: ''
    ${pkgs.systemd}/bin/systemctl --user --machine=${lib.escapeShellArg "${user.name}@.host"} \
      --no-block start zoekt-index-drain.service || true
    ${pkgs.systemd}/bin/systemctl --user --machine=${lib.escapeShellArg "${user.name}@.host"} \
      --no-block start zoekt-index-network-event.service || true
  '') localUsers;
  networkManagerDispatcher = pkgs.writeShellScript "zoekt-index-network-manager-event" ''
    case "$2" in
      up|vpn-up|connectivity-change|dhcp4-change|dhcp6-change)
        ${startUserDrains}
        ;;
    esac
  '';
in
{
  config = lib.mkIf (localUsers != [ ]) {
    # Wi-Fi is owned by NetworkManager on edge nodes. Its dispatcher announces
    # link and route acquisition without adding a timer or connectivity probe.
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
      {
        source = networkManagerDispatcher;
        type = "basic";
      }
    ];

    # USB Ethernet remains owned by networkd even on NetworkManager nodes.
    # Routable is networkd's event that a usable route has appeared.
    services.networkd-dispatcher = lib.mkIf config.systemd.network.enable {
      enable = true;
      rules.zoekt-index-route-up = {
        onState = [ "routable" ];
        script = startUserDrains;
      };
    };
  };
}
