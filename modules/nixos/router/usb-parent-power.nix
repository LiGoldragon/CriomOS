{
  config,
  horizon,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  devices = config.criomos.router.usbParentPowerOn;
  hexadecimalWord = types.strMatching "[0-9a-f]{4}";
  hostName =
    assert builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" horizon.node.name != null;
    horizon.node.name;
  applyPolicy = pkgs.writeShellScript "criomos-router-usb-parent-power" (
    builtins.readFile ./usb-parent-power-apply.sh
  );
  # A USB bus number can change. The PCI controller, root port, and device
  # identity must all match, and only the USB device parent receives the rule.
  render = device: ''
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="/devices/*/${device.pciControllerAddress}/usb*/[0-9]*-${toString device.rootPort}", ATTR{devpath}=="${toString device.rootPort}", ATTR{idVendor}=="${device.usbVendorId}", ATTR{idProduct}=="${device.usbProductId}", ATTR{bcdDevice}=="${device.usbDeviceRevision}", ATTR{serial}=="${device.usbSerialNumber}", PROGRAM=="${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname", RESULT=="${hostName}", ATTR{power/control}="on"
  '';
  declaration =
    lib.findFirst (capability: capability.kind or null == "routerUsbParentPowerOn") { devices = [ ]; }
      (horizon.node.capabilities or [ ]);
  apply = device: ''
    ${applyPolicy} ${lib.escapeShellArgs [
      "/sys/bus/pci/devices"
      hostName
    ]} "$(< /proc/sys/kernel/hostname)" ${lib.escapeShellArgs [
      device.pciControllerAddress
      (toString device.rootPort)
      device.usbVendorId
      device.usbProductId
      device.usbDeviceRevision
      device.usbSerialNumber
    ]}
  '';
in
{
  options.criomos.router.usbParentPowerOn = mkOption {
    type = types.listOf (types.submodule {
      options = {
        pciControllerAddress = mkOption { type = types.strMatching "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}[.][0-7]"; };
        rootPort = mkOption { type = types.ints.between 1 255; };
        usbVendorId = mkOption { type = hexadecimalWord; };
        usbProductId = mkOption { type = hexadecimalWord; };
        usbDeviceRevision = mkOption { type = hexadecimalWord; };
        usbSerialNumber = mkOption { type = types.strMatching "[A-Za-z0-9_-]+"; };
      };
    });
    default = [ ];
    description = ''
      Exact USB device parents kept powered on a declaring router. The
      activation service applies the policy to an already-enumerated device;
      the udev rule covers subsequent enumeration without a resident process.
    '';
  };

  config = mkIf horizon.node.behavesAs.router {
    criomos.router.usbParentPowerOn = lib.mkDefault declaration.devices;

    services.udev.packages = mkIf (devices != [ ]) [
      (pkgs.writeTextDir "lib/udev/rules.d/99-criomos-router-usb-parent-power.rules" (
        lib.concatMapStrings render devices
      ))
    ];

    systemd.services.criomos-router-usb-parent-power = mkIf (devices != [ ]) {
      description = "Keep the declared router USB parents powered";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-trigger.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStrings apply devices;
    };
  };
}
