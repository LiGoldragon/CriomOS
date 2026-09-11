{ lib, horizon, ... }:
let
  inherit (horizon.node) installation;
  inherit (installation) disks bootloader;

  projectedSwapDevices = installation.swapDevices or [ ];
  compressedSwap = horizon.node.compressedSwapMemoryPercent or null;

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
