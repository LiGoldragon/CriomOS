# Removal of Field's pre-declaration USB-downlink hotfix on ouranos: the
# hand-made iptables drop-in for firewall.service, the script it ran, and
# the NetworkManager shared profile that served the downlink. The declared
# UsbDownlink feature owns that hop; while these exist they are a second
# NAT, firewall and DHCP owner of it.
#
# Not a module: imported as a value by network/usb-downlink.nix, which runs
# the program from activation only when the node declares UsbDownlink, and
# by checks/usb-downlink, which runs it against a fixture root.
#
# The program takes the root to clean as its one argument ("/" on a live
# system). It is idempotent and removes nothing else: other drop-ins and
# other NetworkManager profiles stay.
{
  pkgs,
  networkmanager ? null,
  systemd ? pkgs.systemd,
}:
let
  inherit (pkgs) lib;

  # Without NetworkManager on the node, no running daemon holds the deleted
  # profile, so there is nothing to reload.
  reloadNetworkManagerDefinition =
    if networkmanager == null then
      ''
        reloadNetworkManager() { :; }
      ''
    else
      ''
        reloadNetworkManager() {
          if systemctl is-active --quiet NetworkManager.service; then
            timeout 30 nmcli connection reload \
              || echo "usbDownlink: nmcli connection reload failed; the removed profile leaves NetworkManager at its next restart" >&2
          fi
        }
      '';
in
pkgs.writeShellApplication {
  name = "usb-downlink-remove-hotfix";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    systemd
  ]
  ++ lib.optional (networkmanager != null) networkmanager;
  text = ''
    root="''${1:?usage: usb-downlink-remove-hotfix ROOT}"
    root="''${root%/}"

    ${reloadNetworkManagerDefinition}

    remove() {
      if [ -e "$1" ] || [ -L "$1" ]; then
        rm -f -- "$1"
        echo "usbDownlink: removed undeclared hotfix file ''${1#"$root"}" >&2
      fi
    }

    remove "$root/etc/systemd/system.control/firewall.service.d/90-field-prometheus-usb.conf"
    remove "$root/etc/systemd/field-prometheus-usb-firewall.sh"

    profileRemoved=""
    for profile in "$root"/etc/NetworkManager/system-connections/*; do
      [ -f "$profile" ] || continue
      if grep -qxF 'id=prometheus-share-temporary' "$profile"; then
        remove "$profile"
        profileRemoved=yes
      fi
    done

    # On the live system, make a running NetworkManager forget the deleted
    # profile now, which also takes down its shared-mode dnsmasq and NAT.
    if [ -n "$profileRemoved" ] && [ -z "$root" ]; then
      reloadNetworkManager
    fi
  '';
}
