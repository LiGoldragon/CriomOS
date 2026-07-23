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
    # declaration. Its broker remains owned by the matching user profile.
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
    };
  })
]
