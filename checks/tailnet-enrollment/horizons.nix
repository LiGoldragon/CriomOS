# Projected-Horizon fixtures for a two-node tailnet: `controller` carries the
# TailnetController and TailnetClient capabilities, `client` carries
# TailnetClient. Each node's view sees the other in exNodes, as Horizon
# projects every node for every viewpoint.
{
  certificateAuthority ? builtins.replaceStrings [ "\n" ] [ "" ] (
    builtins.readFile ./fixtures/certificate-authority.b64
  ),
}:
let
  behavesAs = {
    bareMetal = false;
    center = false;
    edge = false;
    iso = false;
    largeAi = false;
    router = false;
  };
  fixtureNode = name: capabilities: {
    inherit name capabilities behavesAs;
    criomeDomainName = "${name}.fixture.criome";
    enableNetworkManager = false;
    isNixCache = false;
    nixCacheDomain = null;
    network = {
      linkLocalIps = [ ];
      nodeIp = null;
      wireguardPublicKey = null;
      wireguardProxies = [ ];
      routerInterfaces = null;
    };
    keys.yggdrasil = null;
  };
  controller = fixtureNode "controller" [
    {
      kind = "tailnetClient";
      preauthKeyReference = "tailnetPreauthKeyController";
    }
    {
      kind = "tailnetController";
      inherit certificateAuthority;
      tlsCertificateReference = "headscaleTlsCertificate";
      tlsKeyReference = "headscaleTlsKey";
    }
  ];
  client = fixtureNode "client" [
    {
      kind = "tailnetClient";
      preauthKeyReference = "tailnetPreauthKeyClient";
    }
  ];
  horizonFor = node: exNodes: {
    cluster = "fixture";
    tailnetBaseDomain = "tailnet.fixture.criome";
    domainConfiguration = {
      internalSuffix = "criome";
      publicClusterDomains = [ ];
    };
    inherit node exNodes;
  };
in
{
  controller = horizonFor controller { inherit client; };
  client = horizonFor client { inherit controller; };
  sopsFiles = {
    headscaleTlsCertificate = ./fixtures/headscaleTlsCertificate.sops;
    headscaleTlsKey = ./fixtures/headscaleTlsKey.sops;
    tailnetPreauthKeyController = ./fixtures/tailnetPreauthKeyController.sops;
    tailnetPreauthKeyClient = ./fixtures/tailnetPreauthKeyClient.sops;
  };
}
