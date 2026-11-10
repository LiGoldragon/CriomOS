# The USB Ethernet roles: how a node tells a USB Ethernet NIC from its
# integrated NIC, and a tether from a dongle, without naming any of them.
#
# udev's usb_id builtin gives every NIC behind a USB bus ID_BUS=usb; an
# integrated NIC carries its PCI bus instead. The property is present from
# the first udev event, including while the kernel renames the link, which
# ID_NET_DRIVER is not.
#
# Among USB Ethernet NICs one udev rule sets CRIOMOS_USB_ETHERNET_ROLE, by
# the kernel's own test. A tether, a phone sharing its connection, is an
# uplink: the ipheth driver (an iPhone), or cdc_ether, cdc_ncm or rndis_host
# with a locally administered MAC, the test usbnet uses to name such a link
# usb0 rather than eth0 (a Pixel's tether is cdc_ncm with one; a dongle's
# MAC is the vendor's). Every other USB Ethernet NIC is a downlink.
#
# Not a module: imported as a value by the modules that bind USB Ethernet;
# usb-ethernet-role-rule.nix installs the rule on every node.
{ lib }:
let
  roleProperty = "CRIOMOS_USB_ETHERNET_ROLE";
  usbEthernet = ''SUBSYSTEM=="net", ACTION!="remove", ENV{ID_BUS}=="usb", ATTR{type}=="1", ENV{DEVTYPE}!="wlan", ENV{DEVTYPE}!="wwan"'';
  # The second hex digit of a locally administered MAC has bit 1 set.
  locallyAdministered = ''ATTR{address}=="?[2367abef]:*"'';
in
{
  inherit roleProperty;

  # The classification, for a rules file read after 75-net-description.rules
  # has imported ID_BUS and ID_USB_DRIVER.
  classificationRules = ''
    ${usbEthernet}, ENV{${roleProperty}}="downlink"
    ${usbEthernet}, ENV{ID_USB_DRIVER}=="ipheth", ENV{${roleProperty}}="uplink"
    ${usbEthernet}, ENV{ID_USB_DRIVER}=="cdc_ether|cdc_ncm|rndis_host", ${locallyAdministered}, ENV{${roleProperty}}="uplink"
  '';

  # systemd-networkd [Match] for the USB Ethernet links of one role.
  # `exclude` names links that must never match even if they sit behind a
  # USB bus (a router's declared WAN).
  networkdMatch =
    {
      role ? "downlink",
      exclude ? [ ],
    }:
    {
      Type = "ether";
      Property = [
        "ID_BUS=usb"
        "${roleProperty}=${role}"
      ];
    }
    // lib.optionalAttrs (exclude != [ ]) {
      Name = "!" + lib.concatStringsSep " " exclude;
    };

  # udev match for the USB Ethernet links of one role, for rules that run
  # after the classification.
  udevMatch =
    {
      role ? "downlink",
    }:
    ''${usbEthernet}, ENV{${roleProperty}}=="${role}"'';
}
