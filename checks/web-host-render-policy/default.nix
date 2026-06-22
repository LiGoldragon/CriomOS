{ inputs, pkgs, ... }:

# web-host-render-policy — extended eval-level coverage for the WebHost module
# (cloud-designer, developing the testing side beside the operator's
# web-host-policy check). Covers what web-host-policy does not: multi-site
# projection, the per-site hardening headers on every vhost, and the two
# contract guards the module enforces by THROWING — a non-flake-input source
# and an unsupported renderer. The guards are the module's
# reproducibility-and-safety boundary, so they earn a regression test.
# Host-independent (pure eval), like every *-policy check.

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  bool = value: if value then "true" else "false";

  fixtureInputs = inputs // {
    web-host-fixture = ../web-host-policy/site;
  };

  configurationFor =
    node:
    lib.nixosSystem {
      inherit system;
      specialArgs = {
        inputs = fixtureInputs;
        horizon = {
          inherit node;
        };
      };
      modules = [
        ../../modules/nixos/web-host.nix
        { system.stateVersion = "26.05"; }
      ];
    };

  webHostNode = sites: {
    name = "doris";
    services = [ { WebHost = { inherit sites; }; } ];
  };

  markdownSite = domain: {
    inherit domain;
    source = "flake-input:web-host-fixture";
    renderer = "MarkdownStatic";
  };

  # Two sites -> two virtualHosts, each with its own rendered artifact.
  multiConfiguration =
    (configurationFor (webHostNode [
      (markdownSite "a.test")
      (markdownSite "b.test")
    ])).config;
  vhosts = multiConfiguration.services.nginx.virtualHosts;
  headersOf = domain: vhosts.${domain}.extraConfig;

  # A source that is not flake-input:<name> must be REFUSED — the module renders
  # only from pinned flake inputs (reproducibility guard).
  rawSourceNode = webHostNode [ ((markdownSite "raw.test") // { source = "/some/raw/path"; }) ];
  # An unsupported renderer must be REFUSED — only MarkdownStatic today.
  unsupportedRendererNode = webHostNode [ ((markdownSite "hugo.test") // { renderer = "Hugo"; }) ];

  # Forcing a vhost root drives siteArtifact -> sourcePath, where the guards
  # throw; tryEval turns the throw into success = false.
  rootOf = node: domain: (configurationFor node).config.services.nginx.virtualHosts.${domain}.root;
  evalRefused = node: domain: !(builtins.tryEval (toString (rootOf node domain))).success;
in
pkgs.runCommand "web-host-render-policy" { } ''
  set -eu

  # Multi-site: each domain projects to its own vhost; exactly two vhosts.
  test ${lib.escapeShellArg (bool (vhosts ? "a.test"))} = true
  test ${lib.escapeShellArg (bool (vhosts ? "b.test"))} = true
  test ${lib.escapeShellArg (toString (builtins.length (builtins.attrNames vhosts)))} = 2

  # Per-site hardening headers are present on every vhost.
  printf '%s' ${lib.escapeShellArg (headersOf "a.test")} | grep -F 'X-Content-Type-Options nosniff'
  printf '%s' ${lib.escapeShellArg (headersOf "a.test")} | grep -F 'Referrer-Policy no-referrer'
  printf '%s' ${lib.escapeShellArg (headersOf "a.test")} | grep -F 'X-Frame-Options DENY'
  printf '%s' ${lib.escapeShellArg (headersOf "b.test")} | grep -F 'X-Frame-Options DENY'

  # Contract guards: a raw (non-flake-input) source and an unsupported renderer
  # both REFUSE to evaluate.
  test ${lib.escapeShellArg (bool (evalRefused rawSourceNode "raw.test"))} = true
  test ${lib.escapeShellArg (bool (evalRefused unsupportedRendererNode "hugo.test"))} = true

  touch "$out"
''
