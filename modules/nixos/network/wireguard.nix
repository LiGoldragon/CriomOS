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
    mkIf
    mapAttrsToList
    filterAttrs
    ;
  inherit (horizon) node exNodes;
  inherit (horizon.node) wireguardUntrustedProxies;
  # Step 7b: gate on the underlying Option directly (was hasWireguardPubKey).
  hasWireguardPubKey = horizon.node.wireguardPubKey != null;

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

  validPreNodes = filterAttrs (_: v: v.wireguardPubKey != null) exNodes;

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
