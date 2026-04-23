{ pkgs, inputs, system, ... }:
let
  rustToolchain =
    (inputs.rust-overlay.lib.mkRustBin { } pkgs).stable.latest.default.override {
      extensions = [ "rust-src" "rust-analyzer" "clippy" ];
    };
in
pkgs.mkShell {
  packages = [
    pkgs.nixfmt-rfc-style
    pkgs.jq
    rustToolchain
  ];
}
