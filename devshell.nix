{ pkgs, inputs, ... }:
let
  rustToolchain = (inputs.rust-overlay.lib.mkRustBin { } pkgs).stable.latest.default.override {
    extensions = [
      "rust-src"
      "rust-analyzer"
      "clippy"
    ];
  };

  # Sibling repos managed by ghq under /git/ exposed as symlinks in
  # ./repos/ at devshell entry.
  linkedRepos = [
    "lore"
    # CriomOS cluster
    "CriomOS-home"
    "CriomOS-emacs"
    "horizon-rs"
    # adjacent
    "lojix-cli"
    "brightness-ctl"
    "clavifaber"
    "goldragon"
  ];

  linkSiblingRepos = ''
    mkdir -p repos
    # Remove stale symlinks before re-creating
    find repos -maxdepth 1 -type l -exec rm {} \;
    ${pkgs.lib.concatMapStringsSep "\n" (name: ''
      if [ -d "/git/github.com/LiGoldragon/${name}" ]; then
        ln -sfn "/git/github.com/LiGoldragon/${name}" "repos/${name}"
      else
        echo "warn: /git/github.com/LiGoldragon/${name} not found; skipping symlink" >&2
      fi
    '') linkedRepos}
  '';
in
pkgs.mkShell {
  packages = [
    pkgs.nixfmt-rfc-style
    pkgs.jq
    rustToolchain
  ];

  shellHook = ''
    ${linkSiblingRepos}
  '';
}
