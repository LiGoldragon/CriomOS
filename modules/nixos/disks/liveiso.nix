{
  pkgs,
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkOverride;
  inherit (horizon) node;
  inherit (horizon.node) behavesAs;

  criomosVersion = "unversioned"; # TODO

in
{
  users.users.root.initialPassword = "r";

  boot = {
    supportedFilesystems = mkOverride 10 [
      "ext2"
      "ext3"
      "ext4"
      "btrfs"
      "vfat"
      "xfs"
      "ntfs"
      "ntfs3g"
    ];
  };

  hardware.enableAllFirmware = behavesAs.bareMetal;

  isoImage = {
    isoBaseName = lib.mkForce "CriomOS-isoImage-${node.criomeDomainName}";
    volumeID = "CriomOS-${criomosVersion}-${pkgs.stdenv.hostPlatform.uname.processor}";

    makeUsbBootable = true;
    makeEfiBootable = true;
  };
}
