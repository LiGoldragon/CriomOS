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

  hasWireguardPubKey =
    horizon.node.hasWireguardPubKey or ((horizon.node.wireguardPubKey or null) != null);

  wireguardUntrustedProxies = horizon.node.wireguardUntrustedProxies or [ ];

  mkUntrustedProxy = untrustedProxy: {
    inherit (untrustedProxy) publicKey endpoint;
    allowedIPs = [ "0.0.0.0/0" ];
  };

  mkUntrustedProxyIp = untrustedProxy: untrustedProxy.interfaceIp;

  untrustedProxiesPeers = map mkUntrustedProxy wireguardUntrustedProxies;

  untrustedProxiesIps = map mkUntrustedProxyIp wireguardUntrustedProxies;

  mkNodePeer = nodeName: peerNode: {
    allowedIPs = [ peerNode.nodeIp ];
    publicKey = peerNode.wireguardPubKey;
    endpoint = "wg.${peerNode.criomeDomainName}:51820";
  };

  validPreNodes =
    filterAttrs (
      nodeName: peerNode:
      peerNode.hasWireguardPubKey or ((peerNode.wireguardPubKey or null) != null)
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
          ips = [ node.nodeIp ];
          inherit privateKeyFile;
          peers = nodePeers;
          listenPort = 51820;
        };

      };
    };
  };

}
