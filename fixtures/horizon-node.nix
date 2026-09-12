# One real Horizon node projection, for the checks that evaluate CriomOS NixOS
# modules without a materialized deployment.
#
# `horizon-projection.json` is not hand-written.  It is the exact output of the
# real producer,
#
#   horizon-cli --node atlas < horizon-definition.datom
#
# run against the horizon-rs revision this flake pins.  Lojix's materialized
# `horizon` input is `builtins.fromJSON (builtins.readFile ./horizon.json)` over
# that same serialization, so a check reading this file sees precisely the
# attribute set a deploy-time evaluation sees.  `horizon-definition.datom` is
# the composed definition it came from, kept beside it so the regeneration is
# reproducible.  Regenerate both when the pinned horizon-rs revision moves;
# never edit either to make a check pass.
#
# A fixture authored to match its consumer can never disagree with it, and that
# is what went wrong before this file: each metal check hand-wrote its own
# `horizon.node`, and the four of them disagreed with each other and with the
# projection — a flat `machine.model` where the module reads
# `machine.hardware.model`, a six-field `behavesAs`, and `chipIsIntel` /
# `modelIsThinkpad` / `computerIs` / `handleLidSwitch*` fields horizon-rs
# deleted in f1a5eca — staying green on fields that no longer exist.
#
# `node overrides` applies `overrides` recursively over the projection, so a
# check states only the fields its own assertion is about.
{ lib }:
let
  producerNode = (builtins.fromJSON (builtins.readFile ./horizon-projection.json)).node;

in
{
  inherit producerNode;

  node = overrides: lib.recursiveUpdate producerNode overrides;
}
