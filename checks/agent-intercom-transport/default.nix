{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  homeInput = {
    packages = {
      ${system}.agent-intercom = pkgs.hello;
    };
  };

  node = name: services: {
    inherit name services;
    adminSshPubKeys = [ ];
    behavesAs.edge = false;
  };
  gatewaySshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA";
  gatewayUser = {
    name = "intercom-user";
    trust.min = true;
    sshPubKeys = [ gatewaySshPublicKey ];
    agentIntercomGatewaySshPubKey = gatewaySshPublicKey;
    extraGroups = [ ];
    enableLinger = false;
  };

  configurationFor =
    horizon:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit horizon;
        inputs = inputs // {
          criomos-home = homeInput;
        };
      };
      modules = [
        ../../modules/nixos/users.nix
        ../../modules/nixos/agent-intercom.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  gateway = node "gateway" [ { AgentIntercomGateway = { }; } ];
  peer = node "peer" [ { AgentIntercomPeer = { }; } ];
  gatewayConfiguration = configurationFor {
    node = gateway;
    exNodes = {
      peer = peer;
    };
    users.intercom-user = gatewayUser;
  };
  peerConfiguration = configurationFor {
    node = peer;
    exNodes = {
      gateway = gateway;
    };
    users.intercom-user = gatewayUser;
  };
  module = ../../modules/nixos/agent-intercom.nix;
in
pkgs.runCommand "agent-intercom-transport-contract" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -eu

  test ${lib.escapeShellArg gatewayConfiguration.services.gnome.at-spi2-core.enable} = 1
  test ${lib.escapeShellArg peerConfiguration.services.openssh.settings.AllowStreamLocalForwarding} = no
  test ${lib.escapeShellArg peerConfiguration.services.openssh.settings.StreamLocalBindUnlink} = yes
  test ${lib.escapeShellArg (toString (builtins.elem gatewaySshPublicKey peerConfiguration.users.users.intercom-user.openssh.authorizedKeys.keys))} = 1
  printf '%s' ${lib.escapeShellArg peerConfiguration.services.openssh.extraConfig} | grep -F 'Match User intercom-user'
  printf '%s' ${lib.escapeShellArg peerConfiguration.services.openssh.extraConfig} | grep -F 'AllowStreamLocalForwarding remote'
  test ${lib.escapeShellArg (toString (builtins.elem pkgs.python3 peerConfiguration.environment.systemPackages))} = 1

  grep -F 'AgentIntercomGateway' ${module}
  grep -F 'AgentIntercomPeer' ${module}
  grep -F 'agentIntercomGatewaySshPubKey' ${module}
  grep -F 'AllowStreamLocalForwarding = "no";' ${module}
  grep -F 'AllowStreamLocalForwarding remote' ${module}
  grep -F 'StreamLocalBindUnlink' ${module}
  ! grep -E 'prometheus|ouranos|zeus|tiger' ${module}
  ! grep -F 'broker.sock' ${module}

  touch "$out"
''
