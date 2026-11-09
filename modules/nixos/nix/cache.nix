{
  lib,
  config,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib) mkIf;
  isNixCache = horizon.node.isNixCache or false;

  # The cache's signing key, a sops file in the cluster secrets repository,
  # encrypted to this host's age key. Its public half is this node's Nix
  # public key in the cluster data, which every host trusts.
  signingKeySecretName = "nixCacheSigningKey";
  sopsFiles = inputs.secrets.sopsFiles or { };
in
mkIf isNixCache {
  assertions = [
    {
      assertion = sopsFiles ? ${signingKeySecretName};
      message = "nix cache: inputs.secrets.sopsFiles.${signingKeySecretName} is required by the NixCache capability";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];

  sops.secrets.${signingKeySecretName} = {
    format = "binary";
    sopsFile = sopsFiles.${signingKeySecretName};
    mode = "0400";
    restartUnits = [ "harmonia.service" ];
  };

  # Harmonia serves this host's store as the cluster cache, signing each
  # narinfo as it is served. Priority 30 puts it before cache.nixos.org (40).
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ config.sops.secrets.${signingKeySecretName}.path ];
    settings = {
      bind = "[::]:80";
      priority = 30;
    };
  };
}
