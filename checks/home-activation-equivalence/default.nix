{
  pkgs,
  lib,
  homeConfigurations,
  target,
}:
let
  embeddedActivationPackages = lib.mapAttrs (
    _: userConfiguration: userConfiguration.home.activationPackage
  ) target.config.home-manager.users;

  canonicalActivationPackages = lib.mapAttrs (
    _: homeConfiguration: homeConfiguration.activationPackage
  ) homeConfigurations;

  # Compare package values user-by-user at evaluation time. Coercing both
  # sets into the check environment makes Nix build the compared packages;
  # equal output paths are the Nix identity witness (and therefore the same
  # NAR) for each projected user environment.
  verifiedPackages = lib.mapAttrs (
    userName: embeddedActivationPackage:
    assert canonicalActivationPackages.${userName} == embeddedActivationPackage;
    embeddedActivationPackage
  ) embeddedActivationPackages;
in
pkgs.runCommand "home-activation-equivalence"
  {
    canonicalPackages = lib.concatStringsSep " " (lib.attrValues canonicalActivationPackages);
    embeddedPackages = lib.concatStringsSep " " (lib.attrValues verifiedPackages);
  }
  ''
    test "$canonicalPackages" = "$embeddedPackages"
    touch "$out"
  ''
