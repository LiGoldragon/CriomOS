{ inputs, pkgs, ... }:

# Runtime witness for the Prometheus service-provider POC.  Evaluation checks
# cover the option contract; this boots the Prosody-only deployment with its
# generated TLS material and reaches its declared public listener from another
# guest.
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
          xmppDomain = "xmpp.goldragon.criome.net";
          xmppDomainAliases = [ "xmpp.goldragon.criome" ];
        };
      };

    client =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl pkgs.netcat ];
        # The explicit server hostname keeps this focused two-node test
        # independent of the test driver's machine-name hosts projection.
        networking.extraHosts = "192.168.1.2 server";
        system.stateVersion = "26.05";
      };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("prosody.service")
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

    # The owning root creates the material, while Prosody can read it via the
    # dedicated group. This witnesses the file-access contract used at service
    # startup rather than only checking that the files exist.
    server.succeed(
        "runuser -u prosody -- test -r "
        "/var/lib/prometheus-service-tls/current/certificate.pem"
    )
    server.succeed(
        "runuser -u prosody -- test -r "
        "/var/lib/prometheus-service-tls/current/key.pem"
    )

    server.succeed(
        "openssl x509 -in /var/lib/prometheus-service-tls/current/certificate.pem "
        "-noout -ext subjectAltName | grep -F -- "
        "'DNS:xmpp.goldragon.criome.net, DNS:xmpp.goldragon.criome'"
    )

    # Prosody 13's documented register command consumes two password lines
    # from stdin when no password argument is supplied. This uses a disposable
    # fixture account to witness that supported transport before any SOPS
    # account consumer is enabled.
    server.succeed(
        "printf 'fixture-password\\nfixture-password\\n' | "
        "prosodyctl register fixture xmpp.goldragon.criome.net"
    )

    # The client crosses the server's enabled firewall on Prosody's only
    # declared public listener. Forgejo is a separate option and remains off.
    client.wait_until_succeeds("nc -z -w 5 server 5222")
  '';
}
