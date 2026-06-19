{
  lib,
  horizon,
  ...
}:

# TestVm host emission (design report 47, surface 5; C2 — reports
# 50/4-design-proposal §1).
#
# The host's VM-hosting facts are now CLUSTER-AUTHORED, read off the host's
# own projection (`horizon.node.services`, a `NodeService::VmHost` payload),
# NOT invented in this Nix layer. The host declares one
#
#     (VmHost <guest_subnet> <kvm> <maximum_guests>)
#
# service carrying the tap subnet (one sliced CIDR), KVM availability, and an
# optional capacity ceiling. This replaces the bespoke hardcoded
# `169.254.100+index.1` host-endpoint scheme and the `inputs ? microvm` flake
# probe the live runs hand-rolled.
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
#       endpoint SLICED FROM the host's declared `guest_subnet` (a link-local
#       endpoint in that subnet, NOT the host's routed node IP) and a
#       single-host route to the guest's node IP (/128 for an IPv6 guest IP,
#       /32 for IPv4). It does NOT touch, replace, or reorder the
#       host's existing interfaces / routing / firewall — it is a new tap and
#       the guest's own address only (psyche constraint 5hir5bnz);
#   (c) a networking.hosts entry resolving the GUEST's criome domain to the
#       GUEST's IP (not the host's);
#   (d) a NON-autostart unit — autostart = false keeps the guest out of
#       config.microvm.autostart, so the host builds the guest's
#       microvm@<guest>.service but does not start it at boot. The VM is
#       launched to run a test and stopped after (frame-and-intent 47).
#
# Gating: emission requires the host to DECLARE a VmHost service whose `kvm`
# is `Available`. A host with no VmHost service (or with kvm `Absent`) emits
# nothing, even if it happens to host TestVm guests — the cluster has not
# authored it as a VM host. When `maximum_guests` is declared, the hosted set
# must fit, or evaluation fails (over-subscription is a cluster-model error,
# not something to silently truncate).

let
  inherit (lib)
    mkIf
    mkMerge
    foldl'
    listToAttrs
    findFirst
    toInt
    unique
    optional
    ;
  inherit (builtins)
    head
    split
    elemAt
    attrValues
    filter
    genList
    length
    concatMap
    ;

  thisNode = horizon.node.name;
  exNodes = horizon.exNodes or { };
  clusterName = horizon.cluster.name or thisNode;

  # ---- The host's cluster-authored VmHost capability ---------------------
  #
  # `horizon.node.services` is a list of single-key attrsets, one per
  # NodeService variant (e.g. `{ TailnetClient = {}; }`,
  # `{ VmHost = { guestSubnet = ...; kvm = ...; maximumGuests = ...; }; }`).
  # Find the VmHost entry and read its payload — this is the host fact the
  # generator used to fabricate.
  services = horizon.node.services or [ ];
  vmHostService = findFirst (s: s ? VmHost) null services;
  vmHost = if vmHostService == null then null else vmHostService.VmHost;

  # KVM availability is a closed-set domain value the projection renders as
  # the atom `Available` / `Absent`. Accelerated emission requires Available.
  kvmAvailable = vmHost != null && (vmHost.kvm or "Absent") == "Available";

  # The declared capacity ceiling, if any (maximumGuests is omitted from the
  # projection when the cluster authored no ceiling).
  maximumGuests = if vmHost == null then null else (vmHost.maximumGuests or null);

  stripCidr = ip: if ip == null then null else head (split "/" ip);

  # ---- Per-guest tap endpoint, SLICED from `guest_subnet` -----------------
  #
  # The host's declared `guest_subnet` (e.g. `169.254.100.0/22`) is the CIDR
  # the per-guest taps live in. Each guest gets the host a distinct /32
  # link-local endpoint INSIDE that subnet, keyed deterministically by the
  # guest index — base address + (index + 1). This is NOT the host's routed
  # node IP (preserving 5hir5bnz host-untouched): it is a fresh link-local
  # address carved from the cluster-authored subnet, reachable only over the
  # tap. The guest is reached back via the explicit /32 route to its node IP.
  subnetBase = if vmHost == null then null else stripCidr (vmHost.guestSubnet or null);

  # Split a dotted-decimal IPv4 into its four integer octets.
  octetsOf = ip: map toInt (filter (s: s != "" && !(builtins.isList s)) (split "\\." ip));

  # base + offset within the subnet, carrying across the low octets. The
  # endpoints stay well inside a /22 (1024 hosts) for any realistic guest
  # count, so a plain low-octet add is enough; we still carry into the third
  # octet so a /24-base author also gets distinct addresses.
  hostTapAddress =
    index:
    let
      octets = octetsOf subnetBase;
      o0 = elemAt octets 0;
      o1 = elemAt octets 1;
      o2 = elemAt octets 2;
      o3 = elemAt octets 3;
      # offset by (index + 1) so the first guest's host endpoint is base+1,
      # never the subnet's network address itself.
      flat = o3 + index + 1;
      lowOctet = flat - (flat / 256) * 256;
      thirdOctet = o2 + flat / 256;
    in
    "${toString o0}.${toString o1}.${toString thirdOctet}.${toString lowOctet}";

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

  hostSetOf =
    node:
    (optional ((node.machine.superNode or null) != null) node.machine.superNode)
    ++ (node.machine.superNodes or [ ]);

  allNodes = [ horizon.node ] ++ attrValues exNodes;
  publicKeyOf =
    name:
    let
      node = findFirst (candidate: candidate.name == name) null allNodes;
    in
    if node == null then null else (node.nixPubKeyLine or null);

  # The TestVm guests this node hosts: projected ex_nodes whose machine names
  # this node as super_node and that derive behavesAs.testVm. Only primary
  # hosts emit microvm.vms — the additional co-host relation is for image
  # exchange, not for booting the VM on every peer.
  hostedTestVms = filter (
    node: (node.machine.superNode or null) == thisNode && (node.behavesAs.testVm or false)
  ) (attrValues exNodes);

  # The TestVm guests this node co-hosts: primary OR additional host-set
  # membership. Unit 3's trust boundary is broader than microvm emission: a
  # secondary host must trust the primary host's image key (and conversely) so
  # the declared host-set can exchange the guest image, while non-hosts stay
  # outside the additive trust set.
  coHostedTestVirtualMachines = filter (
    node: (node.behavesAs.testVm or false) && builtins.elem thisNode (hostSetOf node)
  ) (attrValues exNodes);

  coHostNames = concatMap (
    node: filter (name: name != thisNode) (hostSetOf node)
  ) coHostedTestVirtualMachines;
  imageExchangePublicKeys = unique (filter (key: key != null) (map publicKeyOf coHostNames));

  # Respect the declared ceiling: a host that advertises maximum_guests = N
  # must not host more than N TestVm guests. Over-subscription is a cluster
  # authoring error — fail loudly rather than silently truncating the set.
  hostedCount = length hostedTestVms;
  capacityOk = maximumGuests == null || hostedCount <= maximumGuests;
  capacityChecked =
    if capacityOk then
      hostedTestVms
    else
      throw ''
        TestVm host ${thisNode} advertises maximum_guests = ${toString maximumGuests}
        but the projection hosts ${toString hostedCount} TestVm guests. Raise the
        host's VmHost maximum_guests or move guests to another host.
      '';

  indexed = genList (i: {
    index = i;
    guest = elemAt capacityChecked i;
  }) hostedCount;

  guestName = entry: entry.guest.name;
  guestIp = entry: stripCidr (entry.guest.nodeIp or null);
  # A guest's node IP can be either family. An IPv6 host route needs a /128
  # single-host prefix; an IPv4 host route needs /32. A colon in the bare
  # address marks IPv6 (the host tap endpoint stays /32 — it is always an
  # IPv4 link-local address sliced from the IPv4-only guest_subnet).
  guestRoutePrefix = ip: if lib.hasInfix ":" ip then "128" else "32";
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
  # matching ONLY that tap device by name. Gives the host a /32 endpoint
  # SLICED from the declared (IPv4-only) guest_subnet and a single-host route
  # to the guest's node IP — /128 when the guest IP is IPv6, /32 when IPv4.
  # No existing interface, default route, or firewall rule is touched.
  #
  # The 05- filename prefix is load-bearing: systemd-networkd binds each link
  # to the FIRST-sorting matching .network. network/networkd.nix gives a plain
  # center (center && !router) a broad `10-main-eth` (matchConfig.Type =
  # "ether", DHCP = yes). A higher-numbered tap network (the original 70-)
  # sorted AFTER it, so on a plain-center VM host the broad ether DHCP client
  # claimed the guest tap by type before this by-name network applied — the
  # latent plain-center DHCP-claim bug (same issue flagged in Unit B). 05-
  # sorts BEFORE 10-main-eth, so the by-name tap network claims the tap first
  # on ANY host (plain center or router); a router host has no 10-main-eth, so
  # the prefix is simply inert there.
  tapNetworks = listToAttrs (
    map (entry: {
      name = "05-test-vm-${tapId entry.index}";
      value = {
        matchConfig.Name = tapId entry.index;
        address = [ "${hostTapAddress entry.index}/32" ];
        routes = lib.optionals (guestIp entry != null) [
          { Destination = "${guestIp entry}/${guestRoutePrefix (guestIp entry)}"; }
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
  hasCoHostedGuests = coHostedTestVirtualMachines != [ ];
in
mkMerge [
  # Emit only when the host is cluster-authored as a VM host (declares a VmHost
  # service with KVM Available) AND actually hosts at least one TestVm guest.
  (mkIf (hasGuests && kvmAvailable) {
    microvm.vms = vmDeclarations;

    systemd.network.networks = tapNetworks;
    # systemd.network must be on for the tap .network files to apply. The host
    # already runs networkd (center/router nodes set useNetworkd); make the
    # dependency explicit and additive — it only adds the tap networks above.
    networking.useNetworkd = true;
    systemd.network.enable = true;

    networking.hosts = guestHostEntries;
  })

  # Unit 3: emit the scoped image-exchange trust set. This is intentionally
  # additive (`extra-trusted-public-keys`), leaving the cluster-wide
  # `trusted-public-keys` pool owned by the Nix client module untouched. The
  # trust set is computed from all co-hosted TestVm guests (primary OR
  # additional host-set membership), excludes this host's own key, and never
  # admits keyed cluster nodes outside the declared host-set.
  (mkIf (hasCoHostedGuests && kvmAvailable) {
    nix.settings.extra-trusted-public-keys = imageExchangePublicKeys;
  })
]
