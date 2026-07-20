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
  gatewayUsers = builtins.filter (
    user: (user.agentIntercomGatewaySshPubKey or null) != null
  ) (lib.attrValues (horizon.users or { }));
  remoteForwardingConfiguration = lib.concatMapStringsSep "\n" (user: ''
    Match User ${user.name}
      AllowStreamLocalForwarding remote
  '') gatewayUsers;
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
    {
      assertion = !isPeer || gatewayUsers != [ ];
      message = "Agent Intercom peers require at least one projected gateway SSH public key";
    }
  ];

  # OpenSSH supports `remote` as the reverse Unix-socket-only mode. The global
  # denial is overridden only for Horizon-derived identities whose matching
  # public keys users.nix installs. This preserves ordinary SSH access without
  # granting arbitrary authenticated users stream-local forwarding.
  services.openssh.settings = lib.mkIf isPeer {
    AllowStreamLocalForwarding = "no";
    StreamLocalBindUnlink = "yes";
  };
  services.openssh.extraConfig = lib.mkIf isPeer remoteForwardingConfiguration;

  # The remote tunnel health probe runs on the peer through the normal system
  # profile, so it has no store-path or per-user-profile assumption. Python is
  # the upstream stale-socket safety probe dependency. The desktop gateway
  # enables AT-SPI and already receives /dev/uinput access from the typed edge
  # user policy, preserving Electron sandboxing and keeping Computer Use on
  # supported portal/accessibility/input paths.
  environment.systemPackages = [ agentIntercomPackage ] ++ lib.optionals isPeer [ pkgs.python3 ];
  services.gnome.at-spi2-core.enable = lib.mkIf isGateway true;
}
