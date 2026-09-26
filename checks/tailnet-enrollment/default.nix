{ inputs, pkgs, ... }:

# End-to-end tailnet enrollment on two NixOS machines built from the CriomOS
# tailnet modules and fixture cluster data. The controller serves Headscale
# with a sops-held certificate issued by a fixture cluster CA; both nodes
# trust that CA through the system store; each node enrolls with its own
# preauth key through the declared oneshot, and each then sees the other as
# a peer. Re-running the oneshot on a healthy node must not re-register it.
#
# Every key under ./fixtures is snakeoil made for this test alone: the age
# identity, the P-256 CA (whose private key was discarded) and the server
# certificate and key encrypted to that identity. The preauth key ciphertexts
# hold a placeholder: Headscale mints real keys at runtime, and the test
# writes them into the decrypted secret files, as an operator's sops
# ciphertext would deliver them.
let
  constants = inputs.criomos-lib.lib.constants;
  fixtures = import ./horizons.nix { };
  controlPort = toString constants.network.headscale.port;

  tailnetNode =
    horizon:
    { nodes, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/network/tailnet-trust.nix
        ../../modules/nixos/network/headscale.nix
        ../../modules/nixos/network/tailscale.nix
      ];
      _module.args = {
        inherit constants horizon;
        inputs.secrets.sopsFiles = fixtures.sopsFiles;
      };
      system.stateVersion = "26.05";
      networking.hostName = horizon.node.name;
      networking.extraHosts = ''
        ${nodes.controller.networking.primaryIPAddress} controller.fixture.criome
      '';
      # sops-nix refuses a key in the store; place the fixture identity in
      # /run before secrets are decrypted.
      sops.age.keyFile = "/run/tailnet-fixture/age.key";
      system.activationScripts.tailnetFixtureAgeKey.text = ''
        install -D -m 0400 ${./fixtures/age.key} /run/tailnet-fixture/age.key
      '';
      system.activationScripts.setupSecrets.deps = [ "tailnetFixtureAgeKey" ];
      sops.age.sshKeyPaths = [ ];
      sops.gnupg.sshKeyPaths = [ ];
      environment.systemPackages = [
        pkgs.jq
        pkgs.openssl
      ];
    };
in
pkgs.testers.nixosTest {
  name = "tailnet-enrollment";

  nodes.controller = {
    imports = [ (tailnetNode fixtures.controller) ];
    # The test network has no route to Tailscale's DERP map; serve an
    # embedded DERP region instead.
    services.headscale.settings.derp = {
      urls = [ ];
      server = {
        enabled = true;
        region_id = 999;
        stun_listen_addr = "0.0.0.0:3478";
      };
    };
    networking.firewall.allowedUDPPorts = [ 3478 ];
  };

  nodes.client = tailnetNode fixtures.client;

  testScript = ''
    import json

    start_all()
    controller.wait_for_unit("headscale.service")
    controller.wait_for_open_port(${controlPort})
    client.wait_for_unit("tailscaled.service")

    # The system trust store accepts the served certificate for the
    # controller's current name.
    client.succeed(
        "openssl s_client -connect controller.fixture.criome:${controlPort} "
        "-servername controller.fixture.criome -CAfile /etc/ssl/certs/ca-certificates.crt "
        "-verify_return_error "
        "-verify_hostname controller.fixture.criome </dev/null"
    )

    # Headscale mints one reusable preauth key per node; each lands where
    # that node's sops secret is decrypted.
    controller.succeed("headscale users create fixture")
    user_id = json.loads(controller.succeed("headscale users list -o json"))[0]["id"]

    # The operator's minting pipe relies on the default output being the key
    # alone: one line, no other words.
    minted = controller.succeed(
        f"headscale preauthkeys create --user {user_id} --reusable --expiration 1h"
    )
    assert len(minted.strip().split()) == 1 and minted.count("\n") <= 1, (
        f"preauthkeys create printed more than the key: {minted!r}"
    )
    for machine, secret in [
        (controller, "tailnetPreauthKeyController"),
        (client, "tailnetPreauthKeyClient"),
    ]:
        key = json.loads(
            controller.succeed(
                f"headscale preauthkeys create --user {user_id} --reusable --expiration 1h -o json"
            )
        )["key"]
        machine.succeed(f"printf '%s\\n' {key} > /run/secrets/{secret}")
        machine.succeed("systemctl restart tailnet-enroll.service")

    for machine in [controller, client]:
        machine.wait_until_succeeds(
            "tailscale status --json | jq -e '.BackendState == \"Running\"'", timeout=180
        )

    client.wait_until_succeeds(
        "tailscale status --json | jq -e '[.Peer[] | .HostName] | index(\"controller\") != null'",
        timeout=120,
    )
    controller.wait_until_succeeds(
        "tailscale status --json | jq -e '[.Peer[] | .HostName] | index(\"client\") != null'",
        timeout=120,
    )
    client.log(client.succeed("tailscale status"))

    # The declared login server is the controller's domain from cluster data.
    client.succeed(
        "tailscale debug prefs | jq -e '.ControlURL == \"https://controller.fixture.criome:${controlPort}\"'"
    )

    # A healthy node is never re-registered.
    before = controller.succeed("headscale nodes list -o json | jq -c '[.[] | .id] | sort'")
    client.succeed("systemctl restart tailnet-enroll.service")
    client.succeed(
        "journalctl -u tailnet-enroll.service -b | grep -F 'already enrolled, not re-registering'"
    )
    after = controller.succeed("headscale nodes list -o json | jq -c '[.[] | .id] | sort'")
    assert before == after, f"re-running enrollment changed the node set: {before} -> {after}"
    assert len(json.loads(after)) == 2, f"expected two nodes, got {after}"
  '';
}
