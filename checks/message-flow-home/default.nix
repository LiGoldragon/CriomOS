{ inputs, pkgs, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;
  homeChecks = inputs.criomos-home.checks.${system};
  flowService = homeChecks.flow-service-path;
  messageFlowWiring = homeChecks.message-flow-wiring;
in
pkgs.runCommand "message-flow-home-consumer" { } ''
  test -e ${flowService}
  test -e ${messageFlowWiring}
  touch "$out"
''
