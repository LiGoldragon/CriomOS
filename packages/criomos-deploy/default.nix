{ pkgs, ... }:

let
  deploy = pkgs.writeShellScriptBin "criomos-deploy" (builtins.readFile ./deploy.sh);
  reload-shell = pkgs.writeShellScriptBin "criomos-reload-shell" (builtins.readFile ./reload-shell.sh);
in
pkgs.symlinkJoin {
  name = "criomos-deploy";
  paths = [ deploy reload-shell ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    for bin in $out/bin/*; do
      wrapProgram "$bin" \
        --prefix PATH : ${pkgs.lib.makeBinPath [
          pkgs.openssh
          pkgs.jujutsu
          pkgs.coreutils
          pkgs.procps
        ]}
    done
  '';
}
