{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  constants = inputs.criomos-lib.lib.constants;

  # Steps 7a + 7b: typed nixCache (or null), typed yggdrasil (or null);
  # has_*_pub_key shadow fields are gone — consumers gate on the
  # underlying typed sub-record / input bool directly.
  # Step 11: TailnetControllerRole.Server carries port only;
  # base_domain comes from cluster.tailnet.
  tailnetControllerNode = {
    name = "tailnet-controller-test";
    criomeDomainName = "tailnet-controller-test.goldragon.criome";
    enableNetworkManager = true;
    nordvpn = false;
    wifiCert = false;
    nixCache = null;
    linkLocalIps = [ ];
    nodeIp = "10.18.0.50";
    services = {
      tailnet = "Client";
      tailnetController = {
        Server = {
          port = 9443;
        };
      };
    };
    wireguardPubKey = null;
    wireguardUntrustedProxies = [ ];
    yggdrasil = null;
    behavesAs = {
      bareMetal = false;
      center = false;
      edge = true;
      iso = false;
      largeAi = false;
      router = false;
    };
  };

  configuration = lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit constants inputs;
      horizon = {
        cluster = {
          name = "goldragon";
          tailnet = {
            baseDomain = "tailnet.fixture.test";
            tls = null;
          };
        };
        node = tailnetControllerNode;
        exNodes = { };
      };
    };
    modules = [
      ../../modules/nixos/network/default.nix
    ];
  };

  certificateScript = configuration.config.systemd.services.headscale-selfsigned-cert.script;
  headscalePort = toString configuration.config.services.headscale.port;
  headscaleServerUrl = configuration.config.services.headscale.settings.server_url;
  headscaleBaseDomain = configuration.config.services.headscale.settings.dns.base_domain;
  firewallPorts = builtins.toJSON configuration.config.networking.firewall.allowedTCPPorts;
in
pkgs.runCommand "headscale-selfsigned-cert-route-optional" { } ''
  set -eu

  cat > "$TMPDIR/headscale-selfsigned-cert" <<'SCRIPT'
  ${certificateScript}
  SCRIPT

  grep -F -- '-4 route get 1.1.1.1 2>/dev/null' "$TMPDIR/headscale-selfsigned-cert"
  grep -F -- '|| true' "$TMPDIR/headscale-selfsigned-cert"
  test ${lib.escapeShellArg headscalePort} = 9443
  test ${lib.escapeShellArg headscaleServerUrl} = https://tailnet-controller-test.goldragon.criome:9443
  test ${lib.escapeShellArg headscaleBaseDomain} = tailnet.fixture.test
  echo ${lib.escapeShellArg firewallPorts} | grep -F 9443

  touch "$out"
''
