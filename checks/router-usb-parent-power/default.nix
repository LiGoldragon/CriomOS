{ pkgs, ... }:

pkgs.runCommand "router-usb-parent-power-check" { } ''
  ${pkgs.bash}/bin/bash ${./fixtures.sh} ${../../modules/nixos/router/usb-parent-power-apply.sh}
  touch "$out"
''
