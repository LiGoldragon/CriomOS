{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.criomos.testing.opencode;
in
{
  options.criomos.testing.opencode.enable = lib.mkEnableOption "OpenCode CLI for testing";

  # OpenCode is being tested. Opting in installs only the pinned Nix package;
  # it does not start a server or expose a network listener.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.opencode ];
  };
}
