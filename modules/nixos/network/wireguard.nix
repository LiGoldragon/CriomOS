{
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  inherit (lib)
    mkIf
    mapAttrsToList
    filterAttrs
    ;
  inherit (horizon) node exNodes;

  hasWireguardPubKey = node.network.wireguardPublicKey != null;

  wireguardUntrustedProxies = node.network.wireguardProxies;

  mkUntrustedProxy = untrustedProxy: {
    inherit (untrustedProxy) publicKey endpoint;
    allowedIPs = [ "0.0.0.0/0" ];
  };

  mkUntrustedProxyIp = untrustedProxy: untrustedProxy.interfaceIp;

  untrustedProxiesPeers = map mkUntrustedProxy wireguardUntrustedProxies;

  untrustedProxiesIps = map mkUntrustedProxyIp wireguardUntrustedProxies;

  mkNodePeer = nodeName: peerNode: {
    allowedIPs = [ peerNode.network.nodeIp ];
    publicKey = peerNode.network.wireguardPublicKey;
    endpoint = "wg.${peerNode.criomeDomainName}:51820";
  };

  validPreNodes = filterAttrs (
    nodeName: peerNode: peerNode.network.wireguardPublicKey != null
  ) exNodes;

  nodePeers = mapAttrsToList mkNodePeer validPreNodes;

  privateKeyFile = "/etc/wireguard/privateKey";

in
mkIf hasWireguardPubKey {
  networking = {
    wireguard = {
      enable = true;
      interfaces = {
        wgProxies = {
          ips = untrustedProxiesIps;
          peers = untrustedProxiesPeers;
          inherit privateKeyFile;
        };

        wgNode = {
          ips = [ node.network.nodeIp ];
          inherit privateKeyFile;
          peers = nodePeers;
          listenPort = 51820;
        };

      };
    };
  };

}
