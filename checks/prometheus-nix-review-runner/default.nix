{ pkgs, ... }:
let
  runner = pkgs.writeShellApplication {
    name = "prometheus-nix-review-runner";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../../modules/nixos/prometheus-nix-review-runner.sh;
  };

  successfulNix = pkgs.writeShellScript "successful-nix" ''
    test "$1" = build
    exit 0
  '';

  failingNix = pkgs.writeShellScript "failing-nix" ''
    test "$1" = build
    exit 23
  '';

  interruptingNix = pkgs.writeShellScript "interrupting-nix" ''
    test "$1" = build
    kill -TERM "$PPID"
    exit 0
  '';
in
pkgs.runCommand "prometheus-nix-review-runner" { } ''
  set -eu

  ${runner}/bin/prometheus-nix-review-runner \
    ${successfulNix} "$out/success.json" github:LiGoldragon/CriomOS \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd
  grep -F '"status": "passed"' "$out/success.json"
  grep -F '"exitCode": 0' "$out/success.json"

  if ${runner}/bin/prometheus-nix-review-runner \
    ${failingNix} "$out/failure.json" github:LiGoldragon/CriomOS \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd; then
    exit 1
  fi
  grep -F '"status": "failed"' "$out/failure.json"
  grep -F '"exitCode": 23' "$out/failure.json"

  if ${runner}/bin/prometheus-nix-review-runner \
    ${interruptingNix} "$out/interrupted.json" github:LiGoldragon/CriomOS \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd; then
    exit 1
  fi
  grep -F '"status": "interrupted"' "$out/interrupted.json"
  grep -F '"exitCode": 130' "$out/interrupted.json"
''
