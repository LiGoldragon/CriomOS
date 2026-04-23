{
  lib,
  preClusters,
  config,
  ...
}:
let
  inherit (builtins) mapAttrs;
  inherit (lib) mkOption;
  inherit (lib.types)
    enum
    str
    attrsOf
    submodule
    nullOr
    attrs
    listOf
    ;
  inherit (config.species)
    magnitude
    nodeSpecies
    commonUserOptions
    machineSpecies
    IoOptions
    ;

  NodePreCriomeSpecies = submodule {
    options = {
      ssh = mkOption {
        type = nullOr str;
        default = null;
      };

      yggdrasil = {
        pubKey = mkOption {
          type = nullOr str;
          default = null;
        };

        address = mkOption {
          type = nullOr str;
          default = null;
        };

        subnet = mkOption {
          type = nullOr str;
          default = null;
        };
      };

      nixPubKey = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  nodeSubmodule = {
    options = {
      species = mkOption {
        type = enum nodeSpecies;
        default = "center";
      };

      size = mkOption {
        type = enum magnitude;
        default = 0;
      };

      trust = mkOption {
        type = enum magnitude;
        default = 1;
      };

      machine = mkOption {
        type = machineSpecies;
      };

      io = mkOption {
        type = submodule { options = IoOptions; };
        default = { };
      };

      pubKeys = mkOption {
        type = NodePreCriomeSpecies;
        default = { };
      };

      linkLocalIps = mkOption {
        type = listOf attrs;
        default = [ ];
      };

      nodeIp = mkOption {
        type = nullOr str;
        default = null;
      };

      wireguardPubKey = mkOption {
        type = nullOr str;
        default = null;
      };

      nordvpn = mkOption {
        type = lib.types.bool;
        default = false;
      };

      wifiCert = mkOption {
        type = lib.types.bool;
        default = false;
      };

    };
  };

  domainSubmodule = {
    options = {
      species = mkOption {
        type = enum [ "cloudflare" ];
        default = "cloudflare";
      };
    };
  };

  userSubmodule = {
    options = commonUserOptions;
  };

  clusterSubmodule =
    { name, ... }:
    let
      preCluster = preClusters."${name}";
      mkDefaultNodeTrust = name: node: preCluster.trust.nodes."${name}" or 1;
    in
    {
      options = {
        nodes = mkOption {
          type = attrsOf (submodule nodeSubmodule);
        };

        users = mkOption {
          type = attrsOf (submodule userSubmodule);
        };

        domains = mkOption {
          type = attrsOf (submodule domainSubmodule);
          default = { };
        };

        trust = mkOption {
          type = submodule {
            options = {
              cluster = mkOption {
                type = enum magnitude;
                default = 1;
              };

              clusters = mkOption {
                type = attrsOf (enum magnitude);
              };

              nodes = mkOption {
                type = attrsOf (enum magnitude);
              };

              users = mkOption {
                type = attrsOf (enum magnitude);
              };
            };

            config = {
              nodes = mapAttrs mkDefaultNodeTrust preCluster.nodes;
            };
          };
        };
      };
    }
  ;

in
{
  options = {
    Clusters = mkOption {
      type = attrsOf (submodule clusterSubmodule);
    };
  };

  # Normalize Clusters here
  config.Clusters = preClusters;
}
