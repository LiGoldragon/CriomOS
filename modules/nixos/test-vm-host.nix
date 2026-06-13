{
  lib,
  horizon,
  inputs,
  ...
}:

# TestVm host emission (design report 47, surface 5).
#
# For each projected ex_node that this node HOSTS (machine.superNode ==
# thisNode) and that is a TestVm guest (behavesAs.testVm), this host emits a
# real KVM microVM via microvm.nix: its own kernel + a real virtual disk,
# sized from the guest's projected cores / ramGb / diskGb. NOT an nspawn
# container — the psyche chose the faithful VM (frame-and-intent 47).
#
# Per guest it emits:
#   (a) a microvm.vms.<guest> declaration (qemu/KVM, vcpu/mem/disk from the
#       guest's machine facts, a tap interface, autostart = false);
#   (b) an ADDITIVE host tap: a dedicated systemd.network .network that
#       matches ONLY the guest's tap device by name, gives the host a /32
#       endpoint and a /32 route to the guest's IP. It does NOT touch, replace,
#       or reorder the host's existing interfaces / routing / firewall — it is
#       a new tap and the guest's own address only (psyche constraint
#       5hir5bnz);
#   (c) a networking.hosts entry resolving the GUEST's criome domain to the
#       GUEST's IP (not the host's);
#   (d) a NON-autostart unit — autostart = false keeps the guest out of
#       config.microvm.autostart, so the host builds the guest's
#       microvm@<guest>.service but does not start it at boot. The VM is
#       launched to run a test and stopped after (frame-and-intent 47).
#
# This is purely derived from projected horizon facts: no per-node service
# flag, no hardcoded node name. A host that hosts no TestVm guest emits
# nothing (the fold over exNodes is empty → inert).

let
  inherit (lib)
    mkIf
    foldl'
    listToAttrs
    ;
  inherit (builtins)
    head
    split
    attrValues
    filter
    genList
    ;

  thisNode = horizon.node.name;
  exNodes = horizon.exNodes or { };
  clusterName = horizon.cluster.name or thisNode;

  haveMicrovm = inputs ? microvm;

  stripCidr = ip: if ip == null then null else head (split "/" ip);

  # The TestVm guests this node hosts: projected ex_nodes whose machine names
  # this node as super_node and that derive behavesAs.testVm.
  hostedTestVms = filter (
    n:
    (n.machine.superNode or null) == thisNode && (n.behavesAs.testVm or false)
  ) (attrValues exNodes);

  # Stable, ADDITIVE host-side tap address for a guest's tap. We do NOT reuse
  # the host's own routed node IP; we derive a distinct /32 host endpoint in
  # the link-local 169.254.x.y space keyed by the tap index, so it cannot
  # collide with any cluster-routed address or the host's real interfaces. The
  # guest reaches the host over the tap via this endpoint; the host reaches the
  # guest via the explicit /32 route below. Nothing else on the host changes.
  hostTapAddress = index: "169.254.${toString (100 + index)}.1";

  # microvm interface ids must be short (<= 15 chars for a Linux iface name).
  # `vmt<index>` is stable and well under the limit.
  tapId = index: "vmt${toString index}";

  # Deterministic, locally-administered unicast MAC per guest tap (the
  # 02:.. prefix marks it locally administered). Keyed by index so each guest
  # gets a distinct MAC; additive, never collides with hardware MACs. The last
  # octet is the 1-based index zero-padded to two hex-ish decimal digits
  # (supports up to 99 guests per host, far beyond any real need).
  tapMac =
    index:
    let
      n = index + 1;
      twoDigit = if n < 10 then "0${toString n}" else toString n;
    in
    "02:00:00:00:00:${twoDigit}";

  indexed = genList (i: {
    index = i;
    guest = builtins.elemAt hostedTestVms i;
  }) (builtins.length hostedTestVms);

  guestName = entry: entry.guest.name;
  guestIp = entry: stripCidr (entry.guest.nodeIp or null);
  guestCores = entry: entry.guest.machine.cores or 2;
  guestRamGb = entry: entry.guest.machine.ramGb or 2;
  guestDiskGb = entry: entry.guest.machine.diskGb or 20;
  guestDomain = entry: entry.guest.criomeDomainName or "${guestName entry}.${clusterName}.criome";

  # (a) + (d): the microvm.vms.<guest> declarations.
  vmDeclarations = listToAttrs (
    map (entry: {
      name = guestName entry;
      value = {
        autostart = false; # (d) NON-autostart — launched to test, stopped after.
        config = {
          microvm = {
            hypervisor = "qemu"; # real KVM-accelerated VM, own kernel.
            vcpu = guestCores entry;
            mem = (guestRamGb entry) * 1024; # MiB
            # (a) a real virtual disk — a host-side image auto-created at the
            # declared size, mounted as the guest root. This is a genuine
            # virtual block device, not a shared host store.
            volumes = [
              {
                image = "/var/lib/microvms/${guestName entry}/root.img";
                mountPoint = "/";
                size = (guestDiskGb entry) * 1024; # MiB
                autoCreate = true;
                fsType = "ext4";
                label = "nixos";
              }
            ];
            # (b) the guest side of the tap — a single tap NIC.
            interfaces = [
              {
                type = "tap";
                id = tapId entry.index;
                mac = tapMac entry.index;
              }
            ];
          };
          networking.hostName = guestName entry;
          system.stateVersion = lib.trivial.release;
        };
      };
    }) indexed
  );

  # (b) ADDITIVE host-side tap networking — one .network per guest tap,
  # matching ONLY that tap device by name. Gives the host a /32 endpoint on
  # the tap and a /32 route to the guest's IP. No existing interface, default
  # route, or firewall rule is touched.
  tapNetworks = listToAttrs (
    map (entry: {
      name = "70-test-vm-${tapId entry.index}";
      value = {
        matchConfig.Name = tapId entry.index;
        address = [ "${hostTapAddress entry.index}/32" ];
        routes = lib.optionals (guestIp entry != null) [
          { Destination = "${guestIp entry}/32"; }
        ];
        # Stay strictly local to this tap — never advertise as the host's
        # online path, never claim a default route.
        linkConfig.RequiredForOnline = "no";
      };
    }) indexed
  );

  # (c) networking.hosts resolving each GUEST's criome domain to the GUEST's
  # own IP (the previous VmTesting module wrongly pointed the domain at the
  # host's IP).
  guestHostEntries = foldl' (
    acc: entry:
    let
      ip = guestIp entry;
    in
    if ip == null then acc else acc // { "${ip}" = [ (guestDomain entry) ]; }
  ) { } indexed;

  hasGuests = hostedTestVms != [ ];
in
mkIf (hasGuests && haveMicrovm) {
  microvm.vms = vmDeclarations;

  systemd.network.networks = tapNetworks;
  # systemd.network must be on for the tap .network files to apply. The host
  # already runs networkd (center/router nodes set useNetworkd); make the
  # dependency explicit and additive — it only adds the tap networks above.
  networking.useNetworkd = true;
  systemd.network.enable = true;

  networking.hosts = guestHostEntries;
}
