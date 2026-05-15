{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) listToAttrs optionals;
  inherit (horizon.node)
    builderConfigs
    dispatchersSshPubKeys
    isRemoteNixBuilder
    isDispatcher
    ;

  nixSystemName =
    system:
    {
      Aarch64Linux = "aarch64-linux";
      X86_64Linux = "x86_64-linux";
    }
    ."${system}" or system;

  buildMachineFor =
    builder:
    {
      inherit (builder)
        hostName
        sshUser
        sshKey
      supportedFeatures
      maxJobs
      ;
      system = nixSystemName builder.system;
      systems = map nixSystemName (builder.systems or [ builder.system ]);
      protocol = "ssh-ng";
      speedFactor = 10;
      publicHostKey = builder.publicHostKey;
    };
in
{
  nix = {
    settings = {
      # When this node dispatches a derivation to a remote builder,
      # the builder fetches the dep closure from cache.nixos.org
      # itself rather than streaming through the dispatcher.
      builders-use-substitutes = isDispatcher;
    };

    # Build receiver: this node serves builds over restricted SSH.
    sshServe = {
      enable = isRemoteNixBuilder;
      protocol = "ssh-ng";
      write = true;
      trusted = true;
      keys = dispatchersSshPubKeys;
    };

    # Build dispatcher: this node sends derivations to remote builders.
    distributedBuilds = isDispatcher;
    buildMachines = map buildMachineFor (optionals isDispatcher builderConfigs);
  };

  # known_hosts entries for every builder this dispatcher will connect to.
  programs.ssh.knownHosts = listToAttrs (
    map (b: {
      name = b.hostName;
      value.publicKey = b.publicHostKeyLine;
    }) (optionals isDispatcher builderConfigs)
  );
}
