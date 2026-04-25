# Closure shrinkage — decisions on the audit

Captures the close-out decisions on the [0013-closure-bloat-audit.md](0013-closure-bloat-audit.md)
recommendations.

## What landed (already pushed)

- `Magnitude::Large` added; bulk `atLeastMax` → `atLeastLarge`;
  ouranos demoted to Large
- `atLeastMax` exceptions kept (per Li 2026-04-25): evolution,
  libvirtd, waydroid, obs-studio, gimp/krita/calibre/inkscape, LSPs
- `wantsPrinting` (off by default) gating `printingDriversPkgs` —
  `~300–500 MB`
- Intel decoder rewrite: `intel-media-driver` always when treatAsIntel;
  `vpl-gpu-rt` only when `wantsHwVideoAccel && machine.chipGen >= 12`;
  `intel-compute-runtime` dropped — `~600 MB`
- Removed: firejail, firefox-bin, discord-ptb, appflowy

## Decisions on the remaining audit recommendations

### REJECTED — per-user opt-in fields

The audit proposed adding `User.{preferredBrowser, preferredEditor,
wantsAiAgents, isComm, wantsProductivity, languageFocus}` to
horizon-rs as gates for emacs / vscodium AI extensions /
element+telegram / per-language LSPs / appflowy etc.

**Li 2026-04-25: not adding these.** Closure shrinkage isn't worth
the per-user-opt-in surface area. Keep the schema lean — node-level
opt-ins (`wantsPrinting`, `wantsHwVideoAccel`) are fine, user-level
opt-ins for app preferences are not.

Implications for what stays installed regardless of preference:
- emacs is installed for every user that gets the home profile
- vscodium AI extensions ship with vscodium (where vscodium is
  installed by tier)
- element-desktop + telegram-desktop stay at `atLeastMed` (no isComm
  flag)
- LSPs stay collapsed at `atLeastMax` (per the prior rule); no
  per-language opt-out

### REJECTED — GNOME stack tightening

The audit proposed bumping `gnome-control-center` and the 5 GNOME
services (`at-spi2-core`, `evolution-data-server`, `gnome-keyring`,
`gnome-online-accounts`, `gnome-settings-daemon`) from `atLeastMin`
to `atLeastMed` for ~400–700 MB savings.

**Li 2026-04-25: no — wants all GNOME stack by default on edge
nodes.** Current state ([edge/default.nix:19,105-111](../modules/nixos/edge/default.nix#L19))
already gates these at `atLeastMin` inside the edge module, which
fires on every non-None edge node. That's the desired default; no
change.

Same for `tumbler` — keep at `atLeastMed`, no `hasVideoOutput`
additional gate.

## Net result

The closure shrinkage work is **closed out**. What's installed is
what's wanted. The remaining audit items either depend on the
rejected per-user fields, or were rejected outright.

Future closure work would need a different angle (e.g. nixpkgs
overlay swaps to lighter equivalents, kernel module pruning, locale
trimming). Out of scope for now.

## Process note (self-correcting)

Prior chat reply on the same topic was multi-paragraph with savings
tables and didn't go in a report — that violates AGENTS.md "session-
response style" rule. This is the correction.
