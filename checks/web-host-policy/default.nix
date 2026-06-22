{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  baseNode = {
    name = "plain";
    services = [ ];
  };

  webNode = {
    name = "doris";
    services = [
      {
        WebHost = {
          sites = [
            {
              domain = "example.test";
              source = "flake-input:web-host-fixture";
              renderer = "MarkdownStatic";
            }
          ];
        };
      }
    ];
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inputs = inputs // {
          web-host-fixture = ./site;
        };
        horizon = {
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/web-host.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  baseConfiguration = (configurationFor baseNode).config;
  webConfiguration = (configurationFor webNode).config;
  virtualHost = webConfiguration.services.nginx.virtualHosts."example.test";
  artifact = virtualHost.root;
in
pkgs.runCommand "web-host-policy" { } ''
  set -eu

  test ${lib.escapeShellArg (bool baseConfiguration.services.nginx.enable)} = false
  test ${lib.escapeShellArg (builtins.toJSON baseConfiguration.networking.firewall.allowedTCPPorts)} = '[]'

  test ${lib.escapeShellArg (bool webConfiguration.services.nginx.enable)} = true
  test ${lib.escapeShellArg (bool webConfiguration.services.nginx.serverTokens)} = false
  test ${lib.escapeShellArg (bool virtualHost.forceSSL)} = true
  test ${lib.escapeShellArg (bool virtualHost.enableACME)} = true
  test ${lib.escapeShellArg webConfiguration.security.acme.defaults.email} = hostmaster@example.test
  test ${lib.escapeShellArg (bool (builtins.elem 80 webConfiguration.networking.firewall.allowedTCPPorts))} = true
  test ${lib.escapeShellArg (bool (builtins.elem 443 webConfiguration.networking.firewall.allowedTCPPorts))} = true

  test -f ${artifact}/index.html
  grep -F 'CriomOS WebHost fixture' ${artifact}/index.html
  grep -F 'renders markdown at build time' ${artifact}/index.html

  touch "$out"
''
