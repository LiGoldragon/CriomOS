{ pkgs, ... }:
let observer = pkgs.callPackage ../../packages/usb-downlink-observer { inherit pkgs; };
in pkgs.runCommand "usb-downlink-observer" { } ''
  test -x ${observer}/bin/usb-downlink-observer
  touch $out
''
