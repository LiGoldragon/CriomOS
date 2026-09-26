# Tailnet roles as cluster data declares them. Not a module: headscale.nix,
# tailscale.nix and tailnet-trust.nix import it to agree on one reading of
# the projected Horizon.
#
# The controller is the one node (this node or an ex-node) carrying the
# `tailnetController` capability. Its payload carries the public cluster CA
# certificate (base64 DER) and names the sops secrets holding the control
# server's TLS certificate and key. Each `tailnetClient` names the sops secret
# holding its own reusable preauth key.
{
  lib,
  pkgs,
  horizon,
  constants,
}:
let
  inherit (builtins)
    attrValues
    filter
    head
    length
    match
    stringLength
    substring
    toString
    ;
  inherit (horizon) node;
  nodeServices = import ../node-services.nix { inherit lib; };

  allNodes = [ node ] ++ attrValues (horizon.exNodes or { });
  controllers = filter (candidate: nodeServices.has candidate.capabilities "tailnetController") allNodes;
  controller = if controllers == [ ] then null else head controllers;
  controllerRole =
    if controller == null then { } else nodeServices.payload controller.capabilities "tailnetController";
  clientRole = nodeServices.payload node.capabilities "tailnetClient";

  certificateAuthority = controllerRole.certificateAuthority or null;
  # Base64 DER of an X.509 certificate of at least 256 bytes: an outer
  # SEQUENCE with a two-byte length, which base64 renders as `MII`.
  certificateAuthorityDeclared =
    certificateAuthority != null && match "MII[A-Za-z0-9+/]+={0,2}" certificateAuthority != null;

  pemLineLength = 64;
  pemLines =
    text:
    let
      count = (stringLength text + pemLineLength - 1) / pemLineLength;
    in
    lib.genList (index: substring (index * pemLineLength) pemLineLength text) count;
in
rec {
  isController = nodeServices.has node.capabilities "tailnetController";
  isClient = nodeServices.has node.capabilities "tailnetClient";
  hasRole = isController || isClient;

  controllerDeclared = controller != null;
  controllerCount = length controllers;
  inherit certificateAuthorityDeclared;

  controlPort = constants.network.headscale.port;
  controlDomain = controller.criomeDomainName;
  controlUrl = "https://${controlDomain}:${toString controlPort}";

  tlsCertificateSecret = controllerRole.tlsCertificateReference;
  tlsKeySecret = controllerRole.tlsKeyReference;
  preauthKeySecret = clientRole.preauthKeyReference;

  certificateAuthorityFile =
    if certificateAuthorityDeclared then
      pkgs.writeText "tailnet-certificate-authority.pem" (
        lib.concatStringsSep "\n" (
          [ "-----BEGIN CERTIFICATE-----" ]
          ++ pemLines certificateAuthority
          ++ [
            "-----END CERTIFICATE-----"
            ""
          ]
        )
      )
    else
      throw "tailnet: no cluster CA certificate is declared on the TailnetController";

  assertions = [
    {
      assertion = controllerCount == 1;
      message = "tailnet: cluster data must declare exactly one TailnetController; found ${toString controllerCount}";
    }
    {
      assertion = !controllerDeclared || certificateAuthorityDeclared;
      message = "tailnet: the TailnetController on ${
        if controller == null then "<none>" else controller.name
      } carries no cluster CA certificate (base64 DER beginning MII); mint it and record it in cluster data";
    }
  ];

  # The secret a role names, as sops-nix consumes it. A missing ciphertext is
  # an evaluation error that names the secret and the role asking for it.
  sopsSecret =
    inputs: role: name: attributes:
    let
      sopsFiles = inputs.secrets.sopsFiles or { };
    in
    {
      format = "binary";
      sopsFile =
        sopsFiles.${name}
          or (throw "tailnet: inputs.secrets.sopsFiles.${name} is required by this node's ${role} capability");
    }
    // attributes;
}
