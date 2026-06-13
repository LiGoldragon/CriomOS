{
  lib,
  horizon,
  deployment ? {
    includeHome = true;
  },
  ...
}:

# Lean-guest gate for a TestVm-species node (design report 47, surface 4).
#
# A TestVm node (horizon NodeSpecies::TestVm) projects behavesAs.testVm = true
# and — by construction in horizon-rs — derives NONE of the heavy cluster
# facets: edge / center / router / bareMetal / largeAi are all false. So the
# desktop, metal, router, and LLM module trees (each wrapped in their own
# `mkIf behavesAs.*`) are already inert for it. This module makes the lean
# intent explicit and forces off the two heavy surfaces that are NOT gated on
# a behavesAs facet and would otherwise bloat a test guest:
#
#   - the home-manager / desktop home profile (pulled in by deployment
#     includeHome regardless of role), and
#   - man/nixos documentation (large, useless on a throwaway test target).
#
# CRITICAL: this only SUPPRESSES weight. The guest REMAINS a real, deployable
# CriomOS node — sshd keys-only (normalize.nix), root authorizedKeys =
# adminSshPubKeys (users.nix), its own networking.hosts / ssh_known_hosts, and
# a real root disk (disks/preinstalled.nix from its projected io). None of that
# is touched here, so lojix deploys into it exactly like any node.

let
  inherit (lib) mkIf mkForce optionalAttrs;
  inherit (horizon.node) behavesAs;
  includeHome = deployment.includeHome or true;
in
mkIf behavesAs.testVm (
  {
    # Drop man/nixos doc generation — pointless weight on an on-demand test VM.
    documentation = {
      enable = mkForce false;
      nixos.enable = mkForce false;
      man.enable = mkForce false;
    };
  }
  # No graphical home profile on a test guest. The home-manager option set
  # only exists when deployment.includeHome imported it (criomos.nix), so the
  # suppression is itself gated on includeHome — referencing home-manager.users
  # when the module is absent would be an unknown-option error. mkForce so it
  # wins over the includeHome import.
  // optionalAttrs includeHome {
    home-manager.users = mkForce { };
  }
)
