{ inputs, pkgs, ... }:

# web-host-serve — the LIVE proof for the WebHost module (cloud-designer,
# developing the testing side alongside the operator's eval-level
# web-host-policy check). Where web-host-policy asserts the module produces the
# right nginx/ACME CONFIG, this boots a real node carrying a WebHost service and
# proves the rendered site is actually SERVED over HTTP — the integration the
# eval check cannot reach. Modelled on lib/mkVmTest's runNixOSTest idiom: the
# node carries the cluster-authored service, nothing about the site is
# hand-stubbed beyond the test's HTTP override.
#
# Run on a VM-testing host (Spirit qnf8): QEMU-backed, so `nix flake check`
# belongs on prometheus, not an interactive workstation. The eval-level checks
# (web-host-policy, web-host-render-policy) are the host-independent proofs.

let
  inherit (inputs.nixpkgs) lib;

  # A node declaring exactly the WebHost capability — the same single-key
  # service-attrset shape node-services.nix reads on a real host.
  webNode = {
    name = "doris";
    services = [
      {
        WebHost = {
          sites = [
            {
              domain = "example.test";
              source = "flake-input:web-host-fixture";
              renderer = "MarkdownStatic";
            }
          ];
        };
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "web-host-serve";

  # horizon + the fixture flake input are threaded as specialArgs exactly as a
  # production nixosSystem receives them; the fixture site stands in for the
  # pinned flake-input source the module renders.
  node.specialArgs = {
    horizon = {
      node = webNode;
    };
    inputs = inputs // {
      web-host-fixture = ../web-host-policy/site;
    };
  };

  nodes.doris =
    { lib, ... }:
    {
      imports = [ ../../modules/nixos/web-host.nix ];

      # A hermetic VM cannot reach Let's Encrypt, so serve the SAME immutable
      # artifact over plain HTTP for the live proof. The production TLS/ACME
      # config (forceSSL = enableACME = true) is asserted separately by
      # web-host-policy — this test isolates "does the rendered site serve".
      services.nginx.virtualHosts."example.test" = {
        forceSSL = lib.mkForce false;
        enableACME = lib.mkForce false;
      };

      system.stateVersion = "26.05";
    };

  testScript = ''
    doris.start()
    doris.wait_for_unit("nginx.service")
    doris.wait_for_open_port(80)

    # The markdown rendered at build time is served live from the immutable
    # /nix/store artifact.
    doris.succeed(
        "curl -fsS --resolve example.test:80:127.0.0.1 "
        "http://example.test/ | grep -F 'renders markdown at build time'"
    )

    # The edge serves static files only — the renderer was a build-time
    # dependency and is absent from the running system. Nothing dynamic to
    # compromise.
    doris.fail("command -v zola")
  '';
}
