{
  lib,
  preClusters,
  ...
}:
let
  inherit (builtins) attrNames;
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

  magnitude = [
    0
    1
    2
    3
  ];

  bootloaders = [
    "uefi"
    "mbr"
    "uboot"
  ];
  keyboards = [
    "qwerty"
    "colemak"
  ];

  nodeSpecies = [
    "center"
    "largeAI"
    "largeAI-router"
    "hybrid"
    "edge"
    "edgeTesting"
    "mediaBroadcast"
    "router"
    "routerTesting"
  ];

  clusterNames = attrNames preClusters;

  preCriomeSubmodule = {
    options = {
      ssh = mkOption {
        type = str;
      };

      keygrip = mkOption {
        type = str;
      };
    };
  };

  commonUserOptions = {
    size = mkOption {
      type = enum magnitude;
      default = 0;
    };

    species = mkOption {
      type = enum [
        "code"
        "multimedia"
        "unlimited"
      ];
      default = "Multimedia";
    };

    style = mkOption {
      type = enum [
        "vim"
        "emacs"
      ];
      default = "emacs";
    };

    preCriomes = mkOption {
      type = attrsOf (submodule preCriomeSubmodule);
    };

    keyboard = mkOption {
      type = enum [
        "colemak"
        "qwerty"
      ];
      default = "colemak";
    };

    githubId = mkOption {
      type = nullOr str;
      default = null;
    };

  };

  machineSpecies = submodule {
    options = {
      species = mkOption {
        type = enum [
          "metal"
          "pod"
        ];
        default = "metal";
      };

      arch = mkOption {
        type = nullOr str;
        default = null;
      };

      cores = mkOption {
        type = int;
        default = 1;
      };

      model = mkOption {
        type = nullOr str;
        default = null;
      };

      motherBoard = mkOption {
        type = nullOr (enum motherBoardSpeciesNames);
        default = null;
      };

      superNode = mkOption {
        type = nullOr str;
        default = null;
      };

      superUser = mkOption {
        type = nullOr str;
        default = null;
      };
    };
  };

  IoOptions = {
    keyboard = mkOption {
      type = enum keyboards;
      default = "colemak";
    };

    bootloader = mkOption {
      type = enum bootloaders;
      default = "uefi";
    };

    disks = mkOption {
      type = attrs;
      default = { };
    };

    swapDevices = mkOption {
      type = listOf attrs;
      default = [ ];
    };
  };

  motherBoardSpeciesNames = [ "ondyfaind" ];

in
{
  options = {
    species = mkOption {
      type = attrs;
      default = { };
    };
  };

  config.species = {
    inherit
      commonUserOptions
      IoOptions
      machineSpecies
      keyboards
      bootloaders
      magnitude
      clusterNames
      nodeSpecies
      ;
  };

}
