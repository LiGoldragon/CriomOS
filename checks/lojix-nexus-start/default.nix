{ inputs, pkgs, ... }:

# The runtime half of the Lojix service contract. `checks/lojix-nexus-service`
# asserts the evaluated unit; this boots a real NixOS machine carrying the same
# module, waits for the Nexus to bind both authority-tiered sockets at the paths
# CriomOS exports, and completes one ordinary Query against it.
#
# This is the gate that would have caught the `lojix-daemon <archive>` ExecStart:
# no argument-passing unit can reach a bound socket.
let
  inherit (pkgs.stdenv.hostPlatform) system;
  lojixPackage = inputs.lojix.packages.${system}.default;
in
pkgs.testers.nixosTest {
  name = "lojix-nexus-start";
  nodes.machine =
    { ... }:
    {
      imports = [ ../../modules/nixos/lojix.nix ];
      system.stateVersion = "26.05";
      networking.hostName = "lojix-nexus-start";
      users.groups.lojix = { };
      users.users.lojix = {
        isSystemUser = true;
        group = "lojix";
        home = "/var/lib/lojix";
      };
      services.lojix = {
        enable = true;
        package = lojixPackage;
        user = "lojix";
        group = "lojix";
        nexusHost = "lojix-nexus-start";
      };
    };
  testScript = ''
    start_all()
    machine.wait_for_unit("lojix.service")
    machine.wait_until_succeeds("test -S /run/lojix/ordinary.sock && test -S /run/lojix/meta.sock")

    # The unit runs the pinned package's Nexus with no argument at all.
    machine.succeed(
        "systemctl show lojix.service --property=ExecStart --value | grep -F 'argv[]=${lojixPackage}/bin/lojix-nexus ;'"
    )

    # One ordinary Query, over the ordinary socket, answered by the typed
    # vocabulary. A fresh store knows no node, so the reply is a typed
    # `Queried` carrying nothing — an answer, not a client or frame failure.
    reply = machine.succeed(
        "LOJIX_ORDINARY_SOCKET=/run/lojix/ordinary.sock ${lojixPackage}/bin/lojix 'Query.ByNode.{ fixture-cluster fixture-node None }'"
    )
    machine.log(reply)
    assert reply.startswith("Queried"), f"ordinary Query did not return a typed Queried reply: {reply!r}"
  '';
}
