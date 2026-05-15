{ pkgs, ... }:

let
  inherit (pkgs) lib;
  devshell = builtins.readFile ../../devshell.nix;
in
assert lib.assertMsg (lib.hasInfix "/git/github.com/LiGoldragon" devshell)
  "devshell repo links must use the ghq checkout root under /git/github.com/LiGoldragon";
assert lib.assertMsg (
  !(lib.hasInfix "$HOME/git" devshell)
) "devshell repo links must not use the old $HOME/git checkout layout";

pkgs.runCommand "devshell-repository-layout-check" { } ''
  touch "$out"
''
