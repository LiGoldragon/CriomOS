# criome-auth-integrated-test.nix — a single-node nixosTest whose node carries
# BOTH the criome service module and the persona-router service module on the
# consistent wire generation (signal-criome 0.6 / signal-frame 0.3), proving the
# integrated base composes into one bootable system closure. The criome daemon
# signs as a distinct per-node identity ("node-a") and the persona-router joins
# criome's group so its milestone-3 client can dial the 0660 working socket.
#
# This is the integration base T4 (the two-VM criome-auth witness) is written on
# top of: T4 adds a second node ("node-b"), seeds each node's key into the
# other's criome, adds the spirit seed source, and drives the forward chain. The
# node/service shape here is exactly what T4 instantiates per node.
#
# Needs /dev/kvm to boot. The driver and node closures BUILD on any host (this is
# the integrated-closure-builds witness); only the boot requires a VM-testing
# host (prometheus — never ouranos).

{
  pkgs,
  criomePackage,
  criomeModule,
  routerModule,
  inputs,
  nodeIdentity ? "node-a",
  peerIdentity ? "node-b",
}:

pkgs.testers.runNixOSTest {
  name = "criome_auth_integrated_node_builds";

  # persona-router.nix reads `inputs.router` and `horizon.node.services`; supply
  # both to every node. The criome module is standalone (a `package` option).
  node.specialArgs = {
    inherit inputs;
    horizon = {
      node = {
        services = [
          {
            PersonaRouter = {
              identity = nodeIdentity;
              listenPort = 7440;
              criomeSocketPath = "/run/criome/criome.sock";
              criomeSocketGroup = "criome";
              peers = [
                {
                  identity = peerIdentity;
                  address = "192.168.1.20:7440";
                }
              ];
              actorHomes = [
                {
                  actor = "mirror";
                  process = 0;
                  home = peerIdentity;
                }
              ];
            };
          }
        ];
      };
    };
  };

  nodes.machine =
    { ... }:
    {
      imports = [
        criomeModule
        routerModule
      ];
      services.criome = {
        enable = true;
        package = criomePackage;
        # The distinct per-node signing identity — equal to the co-resident
        # persona-router's identity so the milestone-3 forward verifies on a peer.
        nodeIdentity = nodeIdentity;
        # The peer node's key is seeded into this criome's registry at startup
        # (the v1 hardwired cross-instance trust anchor). Placeholder key/finger
        # for the single-node build; T4 supplies the peer's real public key.
        peerIdentitySeeds = [
          {
            name = peerIdentity;
            publicKey = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
            fingerprint = "${peerIdentity}-fingerprint";
            purpose = "CriomeRoot";
          }
        ];
      };
    };

  # The boot-time witness (for T4 to extend). The driver/closure build does not
  # run this; it runs only when an authorized VM-testing host boots the node.
  testScript = ''
    start_all()

    # Both daemons reach active from their deploy-encoded configs.
    machine.wait_for_unit("criome.service")
    machine.wait_for_unit("persona-router.service")

    # criome signs as the distinct node identity (not the historical Host("criome")).
    machine.wait_until_succeeds("test -S /run/criome/criome.sock")
    receipt = machine.succeed(
        "CRIOME_SOCKET=/run/criome/criome.sock "
        + "${criomePackage}/bin/criome '(LookupIdentity (Host ${nodeIdentity}))'"
    ).strip()
    assert "IdentityReceipt" in receipt and "Active" in receipt, (
        f"criome must self-register Host(${nodeIdentity}) Active, got {receipt!r}"
    )

    # The working socket is group-accessible (0660) so the persona-router can dial it.
    working_mode = machine.succeed("stat -c '%a' /run/criome/criome.sock").strip()
    assert working_mode == "660", f"working socket must be 0660, got {working_mode}"

    # The persona-router process holds criome's group, so its milestone-3 client
    # may connect to the working socket.
    groups = machine.succeed(
        "id -nG $(systemctl show -p MainPID --value persona-router.service | tr -d '\\n')"
    )
    assert "criome" in groups.split(), (
        f"persona-router must hold criome's group for socket access, got {groups!r}"
    )

    print("integrated node GREEN: criome + persona-router active, distinct identity, group socket access")
  '';
}
