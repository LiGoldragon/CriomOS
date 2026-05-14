{ pkgs, ... }:

let
  inherit (pkgs) lib;
  routerModule = builtins.readFile ../../modules/nixos/router/default.nix;
in
assert lib.assertMsg (
  !(lib.hasInfix "saePasswords = " routerModule)
) "router Wi-Fi password must not be inlined with authentication.saePasswords";
assert lib.assertMsg (
  lib.hasInfix "saePasswordsFile" routerModule
) "router Wi-Fi must use hostapd authentication.saePasswordsFile";

pkgs.runCommand "router-wifi-secret-check" { } ''
  touch "$out"
''
