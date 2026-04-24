{
  lib,
  pkgs,
  horizon,
  constants,
  ...
}:
let
  inherit (builtins)
    mapAttrs
    attrNames
    filter
    concatStringsSep
    ;
  inherit (lib)
    mapAttrsToList
    filterAttrs
    ;
  inherit (horizon) node exNodes;
  inherit (horizon.node)
    hasWireguardPubKey
    wireguardUntrustedProxies
    ;

  mkUntrustedProxy = untrustedProxy: {
    inherit (wireguardUntrustedProxies) publicKey endpoint;
    allowedIPs = [ "0.0.0.0/0" ];
  };

  mkUntrustedProxyIp = untrustedProxy: untrustedProxy.interfaceIp;

  untrustedProxiesPeers = map mkUntrustedProxy wireguardUntrustedProxies;

  untrustedProxiesIps = map mkUntrustedProxyIp wireguardUntrustedProxies;

  mkNodePeer = name: node: {
    allowedIPs = [ node.nodeIp ];
    publicKey = node.wireguardPubKey;
    endpoint = "wg.${node.criomeDomainName}:51820";
  };

  validPreNodes = filterAttrs (n: v: v.hasWireguardPubKey) exNodes;

  nodePeers = mapAttrsToList mkNodePeer validPreNodes;

  privateKeyFile = "/etc/wireguard/privateKey";

in
{
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
