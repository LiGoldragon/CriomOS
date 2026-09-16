{ inputs, pkgs, ... }:
inputs.signal-message.packages.${pkgs.stdenv.hostPlatform.system}.notify-datom
