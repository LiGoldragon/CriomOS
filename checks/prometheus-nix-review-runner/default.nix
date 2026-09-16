{ pkgs, ... }:
let
  runner = pkgs.writeShellApplication {
    name = "prometheus-nix-review-runner";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../../modules/nixos/prometheus-nix-review-runner.sh;
  };

  successfulNix = pkgs.writeShellScript "successful-nix" ''
    test "$#" = 9
    test "$1" = build
    test "$2" = --refresh
    test "$3" = --no-link
    test "$4" = --print-out-paths
    test "$5" = --max-jobs
    test "$6" = 0
    test "$7" = --impure
    test "$8" = --expr
    case "$9" in
      *'builtins.fetchGit'*'7c9975afbcf44cb580d1491e7f8447fd1def1fbd'*'checks/prometheus-service-provider-policy'*) ;;
      *) exit 65 ;;
    esac
    exit 0
  '';

  failingNix = pkgs.writeShellScript "failing-nix" ''
    ${successfulNix} "$@"
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
    ${successfulNix} "$out/current.json" github:LiGoldragon/CriomOS \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd
  grep -F '"status": "passed"' "$out/current.json"
  first_run_id=$(${pkgs.gnused}/bin/sed -n 's/  "runId": "\(.*\)",/\1/p' "$out/current.json")

  if ${runner}/bin/prometheus-nix-review-runner \
    ${failingNix} "$out/failure.json" github:LiGoldragon/CriomOS \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd; then
    exit 1
  fi
  grep -F '"status": "failed"' "$out/failure.json"
  grep -F '"exitCode": 23' "$out/failure.json"

  if ${runner}/bin/prometheus-nix-review-runner \
    ${interruptingNix} "$out/current.json" github:LiGoldragon/CriomOS \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd; then
    exit 1
  fi
  grep -F '"status": "interrupted"' "$out/current.json"
  grep -F '"exitCode": 130' "$out/current.json"
  second_run_id=$(${pkgs.gnused}/bin/sed -n 's/  "runId": "\(.*\)",/\1/p' "$out/current.json")
  test "$first_run_id" != "$second_run_id"

  if ${runner}/bin/prometheus-nix-review-runner \
    ${successfulNix} "$out/rejected.json" invalid-source \
    7c9975afbcf44cb580d1491e7f8447fd1def1fbd; then
    exit 1
  fi
  test ! -e "$out/rejected.json"
''
