# A minimal, content-sized DigitalOcean cloud image built declaratively from
# this node's CriomOS configuration (Spirit 2u57 / ad53). Active only for a
# `NodeSpecies::CloudNode` node (the derived `behaves_as.cloud_node` facet);
# inert everywhere else. DigitalOcean is BIOS/GRUB-only, so the image is MBR
# with GRUB on /dev/vda; per-instance ssh-key + network + hostname injection
# and growpart come from the upstream DigitalOcean config the image module
# pulls in (modulesPath + "/virtualisation/digital-ocean-config.nix").
{
  lib,
  inputs,
  horizon,
  ...
}:
let
  inherit (lib) mkIf mkDefault optionals;
  isCloudNode = horizon.node.behavesAs.cloudNode or false;
in
{
  # Import the upstream DigitalOcean image machinery ONLY for a cloud node, so
  # `system.build.digitalOceanImage` exists exactly when this node is a
  # CloudNode and is absent elsewhere — the flake's image output keys on that
  # existence rather than building a wrong image for a non-cloud node.
  imports = optionals isCloudNode [
    (inputs.nixpkgs + "/nixos/modules/virtualisation/digital-ocean-image.nix")
  ];

  config = mkIf isCloudNode {
    # Smallest practical upload: bzip2 over the qcow2.
    virtualisation.digitalOceanImage.compressionMethod = "bzip2";

    # Content-sized: make-disk-image measures the closure and sizes the
    # partition to it (NOT a fixed 60 GB region); growpart (from the upstream
    # digital-ocean-config) then expands / to the real droplet disk on first
    # boot. This is the lever that keeps the image at ~1 GB, not 60.
    virtualisation.diskSize = mkDefault "auto";

    services.qemuGuest.enable = true;

    # Assert the MBR / GRUB-on-/dev/vda contract the DigitalOcean BIOS boot
    # relies on, so a mis-declared node fails the build rather than producing
    # an unbootable droplet.
    boot.loader.grub.enable = true;
    boot.loader.grub.devices = lib.mkForce [ "/dev/vda" ];

    # Minimality: a headless cloud node carries no docs, firmware blobs, or
    # fontconfig. Default kernel/initrd modules are deliberately KEPT — a
    # droplet needs virtio_blk/virtio_net to boot, so we do NOT strip them.
    documentation.enable = mkDefault false;
    documentation.nixos.enable = mkDefault false;
    documentation.man.enable = mkDefault false;
    documentation.doc.enable = mkDefault false;
    hardware.enableAllFirmware = mkDefault false;
    hardware.enableRedistributableFirmware = mkDefault false;
    fonts.fontconfig.enable = mkDefault false;
  };
}
