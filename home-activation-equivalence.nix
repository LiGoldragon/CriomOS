{
  pkgs,
  target,
  homeConfigurations,
}:
let
  # The public deployment output must be the activation package embedded in
  # this Consumer's materialized NixOS target.  Standalone CriomOS-home
  # configurations cannot carry Consumer-owned per-user policy, such as an
  # approved remote-control working root.
  projectedActivationPackages = pkgs.lib.mapAttrs (
    _: homeConfiguration: homeConfiguration.activationPackage
  ) homeConfigurations;

  embeddedActivationPackages = pkgs.lib.mapAttrs (
    _: userConfiguration: userConfiguration.home.activationPackage
  ) target.config.home-manager.users;

  # Compare the public output against the separately materialized target
  # user-by-user.  Coercing both sets into the check environment forces the
  # externally deployed output as well as its target-owned source.
  verifiedPackages = pkgs.lib.mapAttrs (
    userName: embeddedActivationPackage:
    assert projectedActivationPackages.${userName} == embeddedActivationPackage;
    embeddedActivationPackage
  ) embeddedActivationPackages;
in
pkgs.runCommand "home-activation-equivalence"
  {
    projectedPackages = pkgs.lib.concatStringsSep " " (pkgs.lib.attrValues projectedActivationPackages);
    embeddedPackages = pkgs.lib.concatStringsSep " " (pkgs.lib.attrValues verifiedPackages);
  }
  ''
    test "$projectedPackages" = "$embeddedPackages"
    touch "$out"
  ''
