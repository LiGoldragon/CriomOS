{ inputs, pkgs, ... }:

# The evaluated tailnet contract, from cluster data alone: the controller
# serves the sops-held certificate at its current domain name and verifies it
# against the cluster CA before starting; every tailnet node trusts that CA;
# each client enrolls argv-free against the controller named in exNodes; and
# a controller without a declared CA fails evaluation.
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  constants = inputs.criomos-lib.lib.constants;
  fixtures = import ../tailnet-enrollment/horizons.nix { };
  withoutAuthority = import ../tailnet-enrollment/horizons.nix { certificateAuthority = null; };

  configurationFor =
    horizon:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants horizon;
        inputs = inputs // {
          secrets.sopsFiles = fixtures.sopsFiles;
        };
      };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/network/default.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  controller = (configurationFor fixtures.controller).config;
  client = (configurationFor fixtures.client).config;
  unanchored = (configurationFor withoutAuthority.client).config;

  port = toString constants.network.headscale.port;
  # Only the tailnet modules' own assertions; the fixture is not a bootable
  # machine, so generic NixOS assertions are out of scope here.
  failedMessages =
    configuration:
    lib.filter (lib.hasPrefix "tailnet:") (
      map (item: item.message) (lib.filter (item: !item.assertion) configuration.assertions)
    );
  certificateFiles = configuration: map toString configuration.security.pki.certificateFiles;

  facts = {
    serverUrl = controller.services.headscale.settings.server_url;
    tlsCertificatePath = controller.services.headscale.settings.tls_cert_path;
    tlsKeyPath = controller.services.headscale.settings.tls_key_path;
    tlsKeyOwner = controller.sops.secrets.headscaleTlsKey.owner;
    selfSignedUnit = controller.systemd.services ? headscale-selfsigned-cert;
    headscaleRequires = controller.systemd.services.headscale.requires or [ ];
    firewall = controller.networking.firewall.allowedTCPPorts;
    controllerEnrolls = controller.systemd.services ? tailnet-enroll;
    controllerEnrollAfter = controller.systemd.services.tailnet-enroll.after;
    clientServesHeadscale = client.services.headscale.enable;
    clientPreauthSecret = client.sops.secrets ? tailnetPreauthKeyClient;
    clientForeignSecrets = client.sops.secrets ? headscaleTlsKey;
    clientCertificateFiles = certificateFiles client;
    controllerCertificateFiles = certificateFiles controller;
    clientFailures = failedMessages client;
    unanchoredFailures = failedMessages unanchored;
  };
  enrollScript = pkgs.writeText "tailnet-enroll-script" client.systemd.services.tailnet-enroll.script;
  verifyScript = builtins.head (lib.toList controller.systemd.services.headscale.serviceConfig.ExecStartPre);
in
pkgs.runCommand "tailnet-declaration"
  {
    nativeBuildInputs = [ pkgs.jq ];
    factsJson = builtins.toJSON facts;
    passAsFile = [ "factsJson" ];
  }
  ''
    set -eu
    facts="$factsJsonPath"
    check() { jq -e "$1" "$facts" >/dev/null || { echo "failed: $1"; jq . "$facts"; exit 1; }; }

    check '.serverUrl == "https://controller.fixture.criome:${port}"'
    check '.tlsCertificatePath == "/run/secrets/headscaleTlsCertificate"'
    check '.tlsKeyPath == "/run/secrets/headscaleTlsKey"'
    check '.tlsKeyOwner == "headscale"'
    check '.selfSignedUnit == false'
    check '.headscaleRequires | index("headscale-selfsigned-cert.service") == null'
    check '.firewall | index(${port}) != null'
    check '.controllerEnrolls == true'
    check '.controllerEnrollAfter | index("headscale.service") != null'
    check '.clientServesHeadscale == false'
    check '.clientPreauthSecret == true'
    check '.clientForeignSecrets == false'
    check '.clientFailures == []'
    check '.clientCertificateFiles | length == 1'
    check '.clientCertificateFiles == .controllerCertificateFiles'
    check '.unanchoredFailures | map(test("carries no cluster CA certificate")) | any'

    # The CA file is the fixture CA, rewrapped to PEM.
    ca=$(jq -r '.clientCertificateFiles[0]' "$facts")
    grep -qx -- '-----BEGIN CERTIFICATE-----' "$ca"
    tr -d '\n' < ${../tailnet-enrollment/fixtures/certificate-authority.b64} > expected
    grep -v -- '-----' "$ca" | tr -d '\n' > actual
    cmp expected actual

    # Enrollment: declared login server, key only by file path, never re-registers.
    grep -F -- '--login-server=https://controller.fixture.criome:${port}' ${enrollScript}
    grep -F -- '--auth-key=file:/run/secrets/tailnetPreauthKeyClient' ${enrollScript}
    grep -F -- '--hostname=client' ${enrollScript}
    grep -F -- 'NeedsLogin | NoState) ;;' ${enrollScript}
    ! grep -F -- '$(cat' ${enrollScript}
    ! grep -F -- '127.0.0.1' ${enrollScript}

    # Headscale refuses a certificate the CA did not issue or that names
    # another host.
    grep -F -- '-checkhost controller.fixture.criome' ${verifyScript}
    grep -F -- '-CAfile' ${verifyScript}

    touch "$out"
  ''
