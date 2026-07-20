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
  };
  peerConfiguration = configurationFor {
    node = peer;
    exNodes = {
      gateway = gateway;
    };
  };
  module = ../../modules/nixos/agent-intercom.nix;
in
pkgs.runCommand "agent-intercom-transport-contract" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -eu

  test ${lib.escapeShellArg gatewayConfiguration.services.gnome.at-spi2-core.enable} = 1
  test ${lib.escapeShellArg peerConfiguration.services.openssh.settings.AllowStreamLocalForwarding} = yes
  test ${lib.escapeShellArg peerConfiguration.services.openssh.settings.StreamLocalBindUnlink} = yes
  test ${lib.escapeShellArg (toString (builtins.elem pkgs.python3 peerConfiguration.environment.systemPackages))} = 1

  grep -F 'AgentIntercomGateway' ${module}
  grep -F 'AgentIntercomPeer' ${module}
  grep -F 'AllowStreamLocalForwarding' ${module}
  grep -F 'StreamLocalBindUnlink' ${module}
  ! grep -E 'prometheus|ouranos|zeus|tiger' ${module}
  ! grep -F 'broker.sock' ${module}

  touch "$out"
''
