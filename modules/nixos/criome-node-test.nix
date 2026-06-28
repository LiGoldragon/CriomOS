# criome-node-test.nix — a single-node nixosTest that boots a CriomOS system
# carrying modules/nixos/criome.nix and witnesses, from durable state and the
# live socket (not daemon stdout), that the criome service:
#
#   1. reaches active, having sealed its typed NOTA config to rkyv in
#      ExecStartPre and launched `criome-daemon <config.rkyv>` (one argument, no
#      flags);
#   2. binds BOTH its working and meta sockets at 0600;
#   3. answers a real request over the working socket — `LookupIdentity` of its
#      self-registered `Host("criome")` returns an Active `IdentityReceipt`,
#      proving the daemon is live and self-registered (not merely that files
#      exist);
#   4. persists its master key at the store-derived path at 0600 (key custody);
#   5. self-resumes across a restart: the same master key and SEMA store survive
#      (no re-mint, no wipe).
#
# Needs /dev/kvm to boot. The driver and node closures build and evaluate on any
# host; only the boot requires a VM-testing host (per the lane brief, prometheus
# — never ouranos). Named for the constraint it witnesses.

{
  pkgs,
  criomePackage,
  criomeModule,
}:

pkgs.testers.runNixOSTest {
  name = "criome_service_reaches_active_with_both_sockets";

  nodes.machine =
    { ... }:
    {
      imports = [ criomeModule ];
      services.criome = {
        enable = true;
        package = criomePackage;
      };
    };

  testScript = ''
    start_all()

    # (1) The service reaches active: ExecStartPre sealed the rkyv config and
    #     ExecStart launched the daemon.
    machine.wait_for_unit("criome.service")

    # (1 cont.) The encoded rkyv config exists and is the daemon's ONE argument,
    #     with no flags — the deploy discipline held.
    machine.succeed("test -f /run/criome/criome-config.rkyv")
    argv = machine.succeed(
        "tr '\\0' '\\n' < /proc/$(systemctl show -p MainPID --value criome.service)/cmdline"
    ).strip().split("\n")
    print("daemon argv:", argv)
    assert argv[-1] == "/run/criome/criome-config.rkyv", (
        f"daemon's last argument must be the encoded rkyv config, got {argv!r}"
    )
    assert not any(a.startswith("--") for a in argv), f"no flags allowed, got {argv!r}"

    # (2) Both sockets are bound at 0600.
    machine.wait_until_succeeds("test -S /run/criome/criome.sock")
    machine.wait_until_succeeds("test -S /run/criome/criome.sock.meta")
    for socket in ("/run/criome/criome.sock", "/run/criome/criome.sock.meta"):
        mode = machine.succeed(f"stat -c '%a' {socket}").strip()
        assert mode == "600", f"{socket} must be 0600, got {mode}"

    # (3) Live round-trip over the working socket: the daemon self-registered
    #     Host("criome") and answers a real request. This is the un-fakeable
    #     witness — a file-exists check could pass with a dead daemon, an
    #     answered LookupIdentity cannot.
    receipt = machine.succeed(
        "CRIOME_SOCKET=/run/criome/criome.sock "
        + "${criomePackage}/bin/criome '(LookupIdentity (Host criome))'"
    ).strip()
    print("lookup reply:", receipt)
    assert "IdentityReceipt" in receipt and "Active" in receipt, (
        f"criome must answer LookupIdentity for its self-registered host as Active, got {receipt!r}"
    )

    # (4) Key custody: master key persisted at the store-derived path at 0600.
    machine.wait_until_succeeds("test -f /var/lib/criome/criome.masterkey")
    key_mode = machine.succeed("stat -c '%a' /var/lib/criome/criome.masterkey").strip()
    assert key_mode == "600", f"master key must be 0600, got {key_mode}"

    key_before = machine.succeed("sha256sum /var/lib/criome/criome.masterkey").split()[0]
    store_before = machine.succeed("ls -1 /var/lib/criome | sort").strip()

    # (5) Self-resume across a restart: same key + store survive.
    machine.succeed("systemctl restart criome.service")
    machine.wait_for_unit("criome.service")
    machine.wait_until_succeeds("test -S /run/criome/criome.sock")

    key_after = machine.succeed("sha256sum /var/lib/criome/criome.masterkey").split()[0]
    store_after = machine.succeed("ls -1 /var/lib/criome | sort").strip()
    assert key_after == key_before, (
        f"master key must survive restart unchanged, before={key_before} after={key_after}"
    )
    assert store_after == store_before, (
        f"state dir must survive restart, before={store_before!r} after={store_after!r}"
    )

    print(
        "criome node GREEN: service active from a deploy-encoded rkyv config "
        "(one argument, no flags), both 0600 sockets bound, a live LookupIdentity "
        "round-trip answered Active over the working socket, 0600 master key "
        "persisted at the store-derived path, and self-resume across a restart."
    )
  '';
}
