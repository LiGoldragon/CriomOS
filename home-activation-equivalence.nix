{
  pkgs,
  inputs,
  target,
}:
let
  # This evaluates the exact pinned CriomOS-home input in its own output
  # surface.  Its `horizon` and `system` inputs are follows inherited from the
  # materialized outer CriomOS evaluation, but it is not the target's
  # `home-manager.users` projection.
  allCanonicalActivationPackages = pkgs.lib.mapAttrs (
    _: homeConfiguration: homeConfiguration.activationPackage
  ) inputs.criomos-home.homeConfigurations;

  embeddedActivationPackages = pkgs.lib.mapAttrs (
    _: userConfiguration: userConfiguration.home.activationPackage
  ) target.config.home-manager.users;

  # CriomOS-home exposes every Horizon user, while the NixOS target correctly
  # embeds only users present on this node (`hasPubKey`). Compare exactly that
  # target-owned local set; unrelated users must not inflate this host closure.
  canonicalActivationPackages = pkgs.lib.filterAttrs (
    userName: _: builtins.hasAttr userName embeddedActivationPackages
  ) allCanonicalActivationPackages;

  # Compare independently-evaluated pinned Home packages to the target's
  # embedded Home Manager packages user-by-user. Coercing both sets into the
  # check environment builds both witnesses; equal output paths are the Nix
  # identity witness (and therefore the same NAR) for each user environment.
  verifiedPackages = pkgs.lib.mapAttrs (
    userName: embeddedActivationPackage:
    assert canonicalActivationPackages.${userName} == embeddedActivationPackage;
    embeddedActivationPackage
  ) embeddedActivationPackages;
in
pkgs.runCommand "home-activation-equivalence"
  {
    canonicalPackages = pkgs.lib.concatStringsSep " " (pkgs.lib.attrValues canonicalActivationPackages);
    embeddedPackages = pkgs.lib.concatStringsSep " " (pkgs.lib.attrValues verifiedPackages);
  }
  ''
    test "$canonicalPackages" = "$embeddedPackages"
    touch "$out"
  ''
