{ lib, horizon, ... }:
let
  installation = horizon.node.installation;
  compressedSwap = horizon.node.compressedSwapMemoryPercent;

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
  boot.supportedFilesystems = [ "xfs" ];
}
// lib.optionalAttrs (installation != null) {
  boot.loader = {
    grub.enable = installation.bootloader == "Mbr";
    systemd-boot.enable = installation.bootloader == "Uefi";
    efi.canTouchEfiVariables = installation.bootloader == "Uefi";
    generic-extlinux-compatible.enable = installation.bootloader == "Uboot";
  };

  fileSystems = builtins.listToAttrs (
    map (disk: {
      name = disk.mount;
      value = {
        device = disk.device;
        fsType = fsTypeFor disk.fsType;
      }
      // (if disk.options == [ ] then { } else { inherit (disk) options; });
    }) installation.disks
  );

  swapDevices = map swapDeviceConfiguration installation.swapDevices;
}
// lib.optionalAttrs (compressedSwap != null) {
  zramSwap = {
    enable = true;
    memoryPercent = compressedSwap;
  };
}
