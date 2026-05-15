{ pkgs, ... }:

let
  inherit (pkgs) lib;
  criomosModule = builtins.readFile ../../modules/nixos/criomos.nix;
  usersModule = builtins.readFile ../../modules/nixos/users.nix;
in
assert lib.assertMsg (
  !(builtins.pathExists ../../modules/nixos/chroma.nix)
) "legacy system Chroma module must not exist; Chroma is a user daemon using XDG_RUNTIME_DIR";
assert lib.assertMsg (
  !(lib.hasInfix "./chroma.nix" criomosModule)
) "nixosModules.criomos must not import the legacy system Chroma module";
assert lib.assertMsg (
  !(lib.hasInfix "\"chroma\"" usersModule)
) "users.nix must not grant the legacy chroma group";

pkgs.runCommand "legacy-chroma-runtime-check" { } ''
  touch "$out"
''
