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

    # DigitalOcean public networking. The droplet's primary NIC must DHCP, but
    # CriomOS's DHCP-over-networkd unit (network/networkd.nix) is gated on
    # behaves_as.center — which a CloudNode is not — and NetworkManager is off
    # for a lean node, while digital-ocean-config only waits for DHCP rather
    # than providing it. Give the cloud NIC a DHCP-over-networkd config so it
    # gets an address; networkd, not the desktop NetworkManager, owns it.
    # TODO(audit-75 #10): this duplicates the center node's 10-main-eth unit —
    # extract a shared cloud/server DHCP module instead of copying it.
    networking.useNetworkd = lib.mkForce true;
    networking.networkmanager.enable = lib.mkForce false;
    systemd.network.networks."10-cloud-dhcp" = {
      matchConfig.Type = "ether";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };

    # Bootloader and ssh firewall are NOT re-asserted here: grub.enable follows
    # io.bootloader=Mbr in preinstalled.nix, grub.devices=[/dev/vda] comes from
    # the upstream digital-ocean-config, and sshd (keys-only, port 22 +
    # openFirewall) is enabled by normalize.nix. Re-setting them would clobber
    # those seams (audit-75 #9, #34).

    # Minimality: a headless cloud node carries no docs, firmware blobs, or
    # fontconfig. These need mkForce, NOT mkDefault or plain false: normalize.nix
    # sets documentation.enable=true at normal priority, so mkDefault silently
    # loses (the knobs were ineffective — audit-75 #33) and plain false
    # conflicts. mkForce authoritatively suppresses the weight. Default
    # kernel/initrd modules are deliberately KEPT — a droplet needs
    # virtio_blk/virtio_net to boot. TODO(audit-75 #17): minimality belongs in a
    # headless profile/facet, not as mkForce overrides fighting normalize.
    documentation.enable = lib.mkForce false;
    documentation.nixos.enable = lib.mkForce false;
    documentation.man.enable = lib.mkForce false;
    documentation.doc.enable = lib.mkForce false;
    hardware.enableAllFirmware = lib.mkForce false;
    hardware.enableRedistributableFirmware = lib.mkForce false;
    fonts.fontconfig.enable = lib.mkForce false;
  };
}
