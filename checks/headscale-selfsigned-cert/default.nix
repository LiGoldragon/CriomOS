{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  constants = inputs.criomos-lib.lib.constants;

  tailnetControllerNode = {
    name = "tailnet-controller-test";
    criomeDomainName = "tailnet-controller-test.goldragon.criome";
    enableNetworkManager = true;
    hasNordvpnPubKey = false;
    hasWifiCertPubKey = false;
    hasWireguardPubKey = false;
    hasYggPubKey = false;
    isNixCache = false;
    linkLocalIps = [ ];
    nixCacheDomain = null;
    nodeIp = "10.18.0.50";
    tailnetClient = true;
    tailnetController = true;
    wireguardPubKey = "";
    wireguardUntrustedProxies = [ ];
    yggAddress = "200:db8::50";
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
        cluster.name = "goldragon";
        node = tailnetControllerNode;
        exNodes = { };
      };
    };
    modules = [
      ../../modules/nixos/network/default.nix
    ];
  };

  certificateScript = configuration.config.systemd.services.headscale-selfsigned-cert.script;
in
pkgs.runCommand "headscale-selfsigned-cert-route-optional" { } ''
  set -eu

  cat > "$TMPDIR/headscale-selfsigned-cert" <<'SCRIPT'
  ${certificateScript}
  SCRIPT

  grep -F -- '-4 route get 1.1.1.1 2>/dev/null' "$TMPDIR/headscale-selfsigned-cert"
  grep -F -- '|| true' "$TMPDIR/headscale-selfsigned-cert"

  touch "$out"
''
