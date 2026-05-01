{ pkgs, inputs, ... }:
let
  rustToolchain =
    (inputs.rust-overlay.lib.mkRustBin { } pkgs).stable.latest.default.override {
      extensions = [ "rust-src" "rust-analyzer" "clippy" ];
    };

  # Sibling repos under ~/git/ exposed as symlinks in ./repos/
  # at devshell entry. Multi-root workspace (CriomOS.code-workspace)
  # gives editors the same view via additional folders.
  linkedRepos = [
    "lore"
    # CriomOS cluster
    "CriomOS-home"
    "CriomOS-emacs"
    "horizon-rs"
    # transitional / adjacent
    "lojix-cli"
    "lojix-cli-v2"
    "brightness-ctl"
    "clavifaber"
    "goldragon"
  ];

  linkSiblingRepos = ''
    mkdir -p repos
    # Remove stale symlinks before re-creating
    find repos -maxdepth 1 -type l -exec rm {} \;
    ${pkgs.lib.concatMapStringsSep "\n" (name: ''
      if [ -d "$HOME/git/${name}" ]; then
        ln -sfn "$HOME/git/${name}" "repos/${name}"
      else
        echo "warn: $HOME/git/${name} not found; skipping symlink" >&2
      fi
    '') linkedRepos}
  '';
in
pkgs.mkShell {
  packages = [
    pkgs.nixfmt-rfc-style
    pkgs.jq
    rustToolchain

    # Gas City + the tools `gc` shells out to at runtime.
    inputs.gascity.packages.${pkgs.stdenv.hostPlatform.system}.default
    pkgs.tmux
    pkgs.dolt
    pkgs.beads
    pkgs.lsof
    pkgs.procps      # pgrep
    pkgs.util-linux  # flock
  ];

  shellHook = ''
    ${linkSiblingRepos}
  '';
}
