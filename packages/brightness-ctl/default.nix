{ pkgs, flake, ... }:

let
  brightness-ctl-unwrapped = pkgs.rustPlatform.buildRustPackage {
    pname = "brightness-ctl";
    version = "0.1.0";
    src = flake + "/packages/brightness-ctl";
    cargoLock.lockFile = flake + "/packages/brightness-ctl/Cargo.lock";
  };
in
pkgs.symlinkJoin {
  name = "brightness-ctl-0.1.0";
  paths = [ brightness-ctl-unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/brightness-ctl \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.systemd
        pkgs.util-linux
        pkgs.libnotify
      ]}
  '';
}
