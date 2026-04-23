{
  lib,
  clustersSpecies,
  ...
}:
let
  inherit (lib) mkOption;
  inherit (lib.types)
    enum
    str
    attrsOf
    submodule
    nullOr
    int
    listOf
    attrs
    ;

  inherit (clustersSpecies)
    clusterNames
    nodeSpecies
    magnitude
    commonUserOptions
    machineSpecies
    IoOptions
    ;

  exNodeOptions = {
    name = mkOption {
      type = str;
    };

    species = mkOption {
      type = enum nodeSpecies;
      default = "center";
    };

    trust = mkOption {
      type = enum magnitude;
    };

    criomeDomainName = mkOption {
      type = str;
    };

    system = mkOption {
      type = str;
    };

    nbOfBuildCores = mkOption {
      type = int;
      default = 1;
    };

    size = mkOption {
      type = enum magnitude;
    };

    machine = mkOption {
      type = machineSpecies;
    };

    yggPreCriome = mkOption {
      type = nullOr str;
      default = null;
    };

    yggAddress = mkOption {
      type = nullOr str;
      default = null;
    };

    yggSubnet = mkOption {
      type = nullOr str;
      default = null;
    };

    ssh = mkOption {
      type = nullOr str;
      default = null;
    };

    nixPreCriome = mkOption {
      type = nullOr str;
      default = null;
    };

    linkLocalIps = mkOption {
      type = listOf str;
      default = [ ];
    };

    nodeIp = mkOption {
      type = nullOr str;
      default = null;
    };

    wireguardPreCriome = mkOption {
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

    wireguardUntrustedProxies = mkOption {
      type = listOf attrs;
      default = [ ];
    };

    methods = mkOption {
      type = attrs;
      default = { };
    };

    typeIs = mkOption {
      type = attrs;
      default = { };
    };
  };

  clusterSubmodule = {
    options = {
      name = mkOption {
        type = enum clusterNames;
      };

      methods = mkOption {
        type = attrs;
        default = { };
      };
    };
  };

  nodeOptions = exNodeOptions // {
    io = mkOption {
      type = submodule { options = IoOptions; };
      default = { };
    };
  };

  userSubmodule = {
    options = commonUserOptions // {
      name = mkOption {
        type = str;
      };

      trust = mkOption {
        type = enum magnitude;
      };

      methods = mkOption {
        type = attrs;
        default = { };
      };
    };
  };

  horizonOptions = {
    options = {
      cluster = mkOption {
        type = submodule clusterSubmodule;
      };

      node = mkOption {
        type = submodule { options = nodeOptions; };
      };

      exNodes = mkOption {
        type = attrsOf (submodule {
          options = exNodeOptions;
        });
      };

      users = mkOption {
        type = attrsOf (submodule userSubmodule);
      };

      methods = mkOption {
        type = attrs;
        default = { };
      };
    };
  };

in
{
  options = {
    horizon = mkOption {
      type = submodule horizonOptions;
    };

    nodeName = mkOption {
      type = str;
    };

    clusterName = mkOption {
      type = str;
    };

  };

}
