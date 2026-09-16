{ inputs, pkgs, ... }:

# Runtime witness for the Prometheus service-provider POC.  Evaluation checks
# cover the option contract; this boots the enabled module with its generated
# TLS material and reaches both declared public listeners from another guest.
pkgs.testers.nixosTest {
  name = "prometheus-service-provider-vm";
  globalTimeout = 180;

  nodes = {
    server =
      { ... }:
      {
        imports = [
          inputs.sops-nix.nixosModules.sops
          ../../modules/nixos/prometheus-service-provider.nix
        ];
        _module.args.inputs = inputs;
        system.stateVersion = "26.05";
        networking.hostName = "prometheus-service-provider";
        networking.firewall.enable = true;
        criomos.prometheusServiceProvider = {
          enable = true;
          xmppDomain = "chat.test";
          forgejoDomain = "git.test";
        };
      };

    client =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl pkgs.netcat ];
        # The explicit server hostname keeps this focused two-node test
        # independent of the test driver's machine-name hosts projection.
        networking.extraHosts = "192.168.1.1 server";
        system.stateVersion = "26.05";
      };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("prosody.service")
    server.wait_for_unit("forgejo.service")
    server.succeed(
        "test $(systemctl show prometheus-service-tls.service "
        "--property=Result --value) = success && "
        "test $(systemctl show prometheus-service-tls.service "
        "--property=ExecMainStatus --value) = 0"
    )
    server.wait_until_succeeds(
        "test -r /var/lib/prometheus-service-tls/current/certificate.pem "
        "&& test -r /var/lib/prometheus-service-tls/current/key.pem"
    )

    # The owning root creates the material, while both daemons can read it via
    # the dedicated group.  This witnesses the file-access contract used at
    # service startup rather than only checking that the files exist.
    for user in ("prosody", "forgejo"):
        server.succeed(
            "runuser -u " + user + " -- test -r "
            "/var/lib/prometheus-service-tls/current/certificate.pem"
        )
        server.succeed(
            "runuser -u " + user + " -- test -r "
            "/var/lib/prometheus-service-tls/current/key.pem"
        )

    # The client crosses the server's enabled firewall.  Forgejo returns an
    # HTTPS response with the generated certificate, and Prosody accepts TCP
    # client-to-server connections on the only other exposed service port.
    client.wait_until_succeeds(
        "nc -z -w 5 server 5222 && nc -z -w 5 server 3000"
    )
    client.succeed("curl --fail --insecure --connect-timeout 10 https://server:3000/")
  '';
}
