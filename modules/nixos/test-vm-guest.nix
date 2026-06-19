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
#
# HOME: `deployment.includeHome` ALONE decides the home profile (proposal
# decision 4 — the single cluster-decided home flag). When it is false (the lean
# TestVm default the VM-test generator derives), criomos.nix never imports
# userHomes.nix, so home-manager.users is empty and the option set is absent —
# nothing to suppress. When it is EXPLICITLY true, the operator wants the home
# profile (the base-home test isolates exactly this: a lean TestVm that keeps
# the home-manager base profile). So this module does NOT force home-manager.
# users back to {} — doing so would defeat the very flag that requested home and
# make a base-home test impossible. Leanness comes from includeHome=false, not
# from re-wiping an explicitly-requested home.

let
  inherit (lib) mkIf mkForce;
  inherit (horizon.node) behavesAs;
in
mkIf (behavesAs.testVm or false) {
  # Drop man/nixos doc generation — pointless weight on an on-demand test VM.
  # This is the genuine lean win, independent of the home toggle.
  documentation = {
    enable = mkForce false;
    nixos.enable = mkForce false;
    man.enable = mkForce false;
  };
}
