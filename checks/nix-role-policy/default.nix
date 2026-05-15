{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseSize = {
    medium = false;
    large = false;
  };

  baseNode = {
    buildCores = 2;
    builderConfigs = [ ];
    cacheUrls = [ ];
    dispatchersSshPubKeys = [ ];
    isDispatcher = false;
    isNixCache = false;
    isRemoteNixBuilder = false;
    size = baseSize;
  };

  serviceNode = baseNode // {
    buildCores = 8;
    builderConfigs = [
      {
        hostName = "builder.example";
        sshUser = "nix-ssh";
        sshKey = "/etc/ssh/ssh_host_ed25519_key";
        supportedFeatures = [
          "big-parallel"
          "kvm"
          "nixos-test"
        ];
        system = "X86_64Linux";
        systems = [ "X86_64Linux" ];
        maxJobs = 4;
        publicHostKey = "ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        publicHostKeyLine = "builder.example ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
      }
    ];
    cacheUrls = [ "http://nix.cache.example" ];
    dispatchersSshPubKeys = [
      "ssh-ed25519 BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    ];
    isDispatcher = true;
    isNixCache = true;
    isRemoteNixBuilder = true;
    size = {
      medium = true;
      large = true;
    };
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs;
        horizon = {
          cluster.trustedBuildPubKeys = [ "cache.example:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" ];
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/nix/default.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  baseConfiguration = (configurationFor baseNode).config;
  serviceConfiguration = (configurationFor serviceNode).config;

  baseExtraOptions = baseConfiguration.nix.extraOptions;
  serviceExtraOptions = serviceConfiguration.nix.extraOptions;
in
pkgs.runCommand "nix-role-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool (builtins.hasAttr "nixdev" baseConfiguration.users.groups))} = true
  test ${lib.escapeShellArg (toString baseConfiguration.nix.settings.cores)} = 2
  test ${lib.escapeShellArg (toString baseConfiguration.nix.settings.max-jobs)} = 1
  test ${lib.escapeShellArg (bool baseConfiguration.nix.settings.auto-optimise-store)} = true
  test ${lib.escapeShellArg (bool baseConfiguration.nix.sshServe.enable)} = false
  test ${lib.escapeShellArg (bool baseConfiguration.nix.distributedBuilds)} = false
  test ${lib.escapeShellArg (bool baseConfiguration.services.nix-serve.enable)} = false
  test ${lib.escapeShellArg (builtins.toJSON baseConfiguration.nix.buildMachines)} = '[]'

  test ${lib.escapeShellArg (toString serviceConfiguration.nix.settings.cores)} = 8
  test ${lib.escapeShellArg (toString serviceConfiguration.nix.settings.max-jobs)} = 4
  test ${lib.escapeShellArg (bool serviceConfiguration.nix.settings.builders-use-substitutes)} = true
  test ${lib.escapeShellArg (bool serviceConfiguration.nix.sshServe.enable)} = true
  test ${lib.escapeShellArg (bool serviceConfiguration.nix.distributedBuilds)} = true
  test ${lib.escapeShellArg (toString (builtins.length serviceConfiguration.nix.buildMachines))} = 1
  test ${lib.escapeShellArg (builtins.elemAt serviceConfiguration.nix.buildMachines 0).system} = ${lib.escapeShellArg system}
  test ${lib.escapeShellArg (builtins.toJSON (builtins.elemAt serviceConfiguration.nix.buildMachines 0).systems)} = ${lib.escapeShellArg (builtins.toJSON [ system ])}
  test ${lib.escapeShellArg (bool (builtins.hasAttr "builder.example" serviceConfiguration.programs.ssh.knownHosts))} = true
  test ${lib.escapeShellArg (bool serviceConfiguration.services.nix-serve.enable)} = true
  test ${lib.escapeShellArg (bool (builtins.elem 80 serviceConfiguration.networking.firewall.allowedTCPPorts))} = true

  printf '%s' ${lib.escapeShellArg baseExtraOptions} | grep -F 'flake-registry ='
  printf '%s' ${lib.escapeShellArg baseExtraOptions} | grep -F 'experimental-features = nix-command flakes recursive-nix'
  printf '%s' ${lib.escapeShellArg serviceExtraOptions} | grep -F 'keep-derivations = true'
  printf '%s' ${lib.escapeShellArg serviceExtraOptions} | grep -F 'keep-outputs = true'

  touch "$out"
''
