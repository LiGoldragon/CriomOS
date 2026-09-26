# Every node with a tailnet role trusts the cluster CA that issued the
# control server's certificate. The CA is public cluster data, carried on the
# TailnetController capability; it enters the system trust store so
# tailscaled (Go crypto/tls) and every other TLS client verify the control
# server by the controller's current domain name.
{
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  tailnet = import ./tailnet-roles.nix {
    inherit
      lib
      pkgs
      horizon
      constants
      ;
  };
in
{
  config = lib.mkIf tailnet.hasRole {
    assertions = tailnet.assertions;
    security.pki.certificateFiles = [ tailnet.certificateAuthorityFile ];
  };
}
