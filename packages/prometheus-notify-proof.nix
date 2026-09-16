{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "prometheus-notify-proof";
  runtimeInputs = [ pkgs.python3 ];
  text = ''
    exec ${pkgs.python3}/bin/python ${./prometheus-notify-proof.py} "$@"
  '';
}
