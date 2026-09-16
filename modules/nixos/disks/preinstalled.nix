{ lib, horizon, ... }:
let
  # Horizon's current projection stores installation facts in `node.io`.
  # Preserve the older `installation` form for already-pinned consumers; every
  # adapter field below is a direct spelling change from that emitted record.
  legacyInstallation = horizon.node.installation or null;
  io = horizon.node.io or null;
  installation =
    if legacyInstallation != null then
      legacyInstallation
    else if io != null then
      {
        bootloader = io.bootloader;
        disks = lib.mapAttrsToList (mount: disk: {
          inherit mount;
          inherit (disk) device;
          fs_type = disk.fsType;
          options = disk.options or [ ];
        }) io.disks;
        swapDevices = io.swapDevices or [ ];
      }
    else
      throw "preinstalled disks require Horizon node.installation or node.io";
  inherit (installation) disks bootloader;

  projectedSwapDevices = installation.swapDevices or [ ];
  compressedSwap =
    if horizon.node.compressedSwapMemoryPercent or null != null then
      horizon.node.compressedSwapMemoryPercent
    else if io != null then
      io.compressedSwap.memoryPercent or null
    else
      null;

  fsTypeFor =
    ft:
    {
      Ext2 = "ext2";
      Ext3 = "ext3";
      Ext4 = "ext4";
      Btrfs = "btrfs";
      Xfs = "xfs";
      Zfs = "zfs";
      F2fs = "f2fs";
      Bcachefs = "bcachefs";
      Vfat = "vfat";
      Exfat = "exfat";
      Ntfs = "ntfs";
      Tmpfs = "tmpfs";
    }
    .${ft};

  swapDeviceConfiguration =
    swapDevice:
    {
      inherit (swapDevice) device;
    }
    // lib.optionalAttrs ((swapDevice.sizeMebibytes or null) != null) {
      size = swapDevice.sizeMebibytes;
    };

in
{
  boot = {
    supportedFilesystems = [ "xfs" ];

    loader = {
      grub.enable = bootloader == "Mbr";
      systemd-boot.enable = bootloader == "Uefi";
      efi.canTouchEfiVariables = bootloader == "Uefi";
      generic-extlinux-compatible.enable = bootloader == "Uboot";
    };
  };

  fileSystems = lib.mapAttrs (
    _: disk:
    {
      device = disk.device;
      fsType = fsTypeFor disk.fsType;
    }
    // (if disk.options == [ ] then { } else { inherit (disk) options; })
  ) (lib.listToAttrs (map (disk: {
    name = disk.mount;
    value = disk // { fsType = disk.fs_type; };
  }) disks));

  swapDevices = map swapDeviceConfiguration projectedSwapDevices;
}
// lib.optionalAttrs (compressedSwap != null) {
  zramSwap = {
    enable = true;
    memoryPercent = compressedSwap;
  };
}
