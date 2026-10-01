{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) mkForce mkIf;
  inherit (horizon.node) behavesAs enableNetworkManager;

  sharing = builtins.any (c: builtins.isAttrs c && (c.kind or null) == "usbDownlink") (
    horizon.node.capabilities or [ ]
  );
  networkManagerDesktop = enableNetworkManager && !behavesAs.router && !sharing;
in
{
  config = mkIf networkManagerDesktop {
    networking = {
      nameservers = mkForce [ ];
      networkmanager.dns = "systemd-resolved";
      resolvconf.enable = mkForce false;
    };

    services.resolved = {
      enable = true;
      settings.Resolve.FallbackDNS = [
        "1.1.1.1"
        "9.9.9.9"
      ];
    };
  };
}
