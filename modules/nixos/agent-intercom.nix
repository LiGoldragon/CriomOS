{
  horizon,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  nodeServices = import ./node-services.nix { inherit lib; };
  localEnabled = nodeServices.has (horizon.node.services or [ ]) "AgentIntercomLocal";
  graphicalEnabled = nodeServices.has (horizon.node.services or [ ]) "AgentIntercomGraphical";
  agentIntercomPackage =
    inputs.criomos-home.packages.${pkgs.stdenv.hostPlatform.system}.agent-intercom;
in
lib.mkMerge [
  {
    assertions = [
      {
        assertion = !graphicalEnabled || localEnabled;
        message = "graphical Agent Intercom requires local Agent Intercom";
      }
    ];
  }
  (lib.mkIf localEnabled {
    # The local family has one host-local package and no cross-host transport
    # declaration. Its producer exports only distinct Intercom command names;
    # direct `codex` and `claude` remain owned by the matching user profile.
    environment.systemPackages = [ agentIntercomPackage ];
  })
  (lib.mkIf (localEnabled && graphicalEnabled) {
    # Keep Electron sandboxing intact while enabling supported graphical
    # prerequisites: accessibility, portal screencast, and /dev/uinput.
    services.gnome.at-spi2-core.enable = true;
    hardware.uinput.enable = true;
    xdg.portal = {
      enable = true;
      xdgOpenUsePortal = true;
      wlr.enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config = {
        # Keep GTK as the fallback, but require the WLR backend for the
        # capture interfaces Computer Use needs.
        common = {
          default = [ "gtk" ];
          "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
          "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
        };
        # niri-portals.conf takes precedence over portals.conf, so carry the
        # capture selection into its desktop-specific configuration too.
        niri = {
          default = lib.mkDefault [ "gtk" ];
          "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
          "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
        };
      };
    };
  })
]
