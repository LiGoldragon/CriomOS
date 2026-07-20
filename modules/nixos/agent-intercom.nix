{
  config,
  horizon,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  nodeServices = import ./node-services.nix { inherit lib; };
  clusterNodes = [ horizon.node ] ++ lib.attrValues (horizon.exNodes or { });
  gatewayNodes = builtins.filter (
    node: nodeServices.has (node.services or [ ]) "AgentIntercomGateway"
  ) clusterNodes;
  isGateway = nodeServices.has (horizon.node.services or [ ]) "AgentIntercomGateway";
  isPeer = nodeServices.has (horizon.node.services or [ ]) "AgentIntercomPeer";
  enabled = isGateway || isPeer;
  agentIntercomPackage =
    inputs.criomos-home.packages.${pkgs.stdenv.hostPlatform.system}.agent-intercom;
in
lib.mkIf enabled {
  assertions = [
    {
      assertion = !isPeer || builtins.length gatewayNodes == 1;
      message = "Agent Intercom peers require exactly one projected gateway";
    }
    {
      assertion = !isGateway || gatewayNodes == [ horizon.node ];
      message = "Agent Intercom gateway selection must resolve to the current projected gateway node";
    }
  ];

  # The peer accepts only Unix-domain forwarding. The user environment owns
  # the authenticated client and its state; this host-level policy neither
  # exposes TCP nor forwards the authoritative broker socket.
  services.openssh.settings = lib.mkIf isPeer {
    AllowStreamLocalForwarding = "yes";
    StreamLocalBindUnlink = "yes";
  };

  # The remote tunnel health probe runs on the peer through the normal system
  # profile, so it has no store-path or per-user-profile assumption. Python is
  # the upstream stale-socket safety probe dependency. The desktop gateway
  # enables AT-SPI and already receives /dev/uinput access from the typed edge
  # user policy, preserving Electron sandboxing and keeping Computer Use on
  # supported portal/accessibility/input paths.
  environment.systemPackages = [ agentIntercomPackage ] ++ lib.optionals isPeer [ pkgs.python3 ];
  services.gnome.at-spi2-core.enable = lib.mkIf isGateway true;
}
