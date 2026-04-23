{ lib, horizon, ... }:
let
  inherit (builtins) mapAttrs attrNames filter;
  inherit (lib) optionals mkIf optional;

  inherit (horizon.node.io) disks swapDevices bootloader;

in
{
  boot = {
    supportedFilesystems = [ "xfs" ];

    loader = {
      grub.enable = bootloader == "mbr";
      systemd-boot.enable = bootloader == "uefi";
      efi.canTouchEfiVariables = bootloader == "uefi";
      generic-extlinux-compatible.enable = bootloader == "uboot";
    };

  };

  fileSystems = disks;
  inherit swapDevices;

}
