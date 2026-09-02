{ inputs, pkgs, ... }:
let
  flowIdHome = inputs.criomos-home.checks.${pkgs.stdenv.hostPlatform.system}.flow-id;
in
pkgs.runCommand "flow-id-home-consumer" { } ''
  test -e ${flowIdHome}
  touch "$out"
''
