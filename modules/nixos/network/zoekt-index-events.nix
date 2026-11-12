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
    # Built-in Wi-Fi and Ethernet are owned by NetworkManager on ouranos. Its
    # dispatcher announces link and route acquisition without a connectivity probe.
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
      {
        source = networkManagerDispatcher;
        type = "basic";
      }
    ];

    # NM-unmanaged USB uplinks, including the phone, are owned by networkd.
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
