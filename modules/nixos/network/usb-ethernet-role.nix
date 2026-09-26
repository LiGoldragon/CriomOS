# The USB Ethernet bus role: how a node tells a USB Ethernet NIC from its
# integrated NIC without naming either one. udev's usb_id builtin gives
# every NIC behind a USB bus ID_BUS=usb; an integrated NIC carries its PCI
# bus instead. The property is present from the first udev event, including
# while the kernel renames the link, which ID_NET_DRIVER is not.
#
# Not a module: imported as a value by the modules that bind USB Ethernet.
{ lib }:
{
  # systemd-networkd [Match] for USB Ethernet links. `exclude` names links
  # that must never match even if they sit behind a USB bus (a router's
  # declared WAN).
  networkdMatch =
    {
      exclude ? [ ],
    }:
    {
      Type = "ether";
      Property = "ID_BUS=usb";
    }
    // lib.optionalAttrs (exclude != [ ]) {
      Name = "!" + lib.concatStringsSep " " exclude;
    };

  # udev match for the same links, for rules that run after
  # 75-net-description.rules has imported the USB properties. Wireless and
  # WWAN devices behind USB carry their own DEVTYPE and are not Ethernet.
  udevMatch = ''SUBSYSTEM=="net", ENV{ID_BUS}=="usb", ATTR{type}=="1", ENV{DEVTYPE}!="wlan", ENV{DEVTYPE}!="wwan"'';
}
