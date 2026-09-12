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

  # Fields the CriomOS modules still read that the current projection does not
  # emit.  They are kept here, in one place and named for what they are, rather
  # than scattered through the checks as if Horizon had supplied them.
  #
  # `size`: the projection carries a `Magnitude` name ("Zero" | "Min" |
  #   "Medium" | "Large" | "Max"); the modules branch on the "at least this
  #   size" booleans the retired `AtLeast` projection carried.  Deriving those
  #   consumer-side is a separate migration — it touches `metal`, `edge`,
  #   `normalize`, `nspawn` and `nix/retention-agent` together.
  # `wantsPrinting`, `wantsHwVideoAccel`: operator opt-ins that no horizon-rs
  #   revision has ever emitted.  They need either a Horizon field or a
  #   CriomOS-side decision; neither exists yet.
  consumerPending = {
    size = {
      min = true;
      medium = true;
      large = true;
      max = true;
    };
    wantsPrinting = false;
    wantsHwVideoAccel = false;
  };
in
{
  inherit producerNode consumerPending;

  node = overrides: lib.recursiveUpdate (producerNode // consumerPending) overrides;
}
