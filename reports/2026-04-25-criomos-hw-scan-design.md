# 2026-04-25 — criomos-hw-scan design

Tracked as bead `CriomOS-???` (filed below). **Not yet implemented.**

## Problem

Operators add nodes to a goldragon-style cluster proposal by
hand-writing positional nota records. With the new
`Machine.chipGen` + `Machine.ramGb` + `NodeProposal.wantsHwVideoAccel`
fields landed today, three values are now error-prone to fill in by
eye:

- `chipGen`: is "T14 Gen 5 = Meteor Lake" → 12 or 13 or 14? Intel's
  generation numbering is inconsistent between CPU and iGPU ladders.
- `ramGb`: trivial but tedious to look up.
- `model`: should match a string the metal module branches on; easy
  to misspell (`ThinkPadT14Gen5Intel` vs `ThinkpadT14Gen5Intel`).

A small Rust CLI on the target node introspects `/proc` + `/sys` +
DMI and prints values the operator pastes into the proposal.

## Tool shape

Single-binary Rust CLI in its own git repo
(`github:LiGoldragon/criomos-hw-scan`), packaged via crane + fenix per
[tools-documentation/rust/nix-packaging.md](../../tools-documentation/rust/nix-packaging.md).

Two output modes:

```
$ criomos-hw-scan
species:   Metal
arch:      X86_64
cores:     12
model:     ThinkPad T14 Gen 5
chipGen:   12      # Meteor Lake Xe-LPG iGPU
ramGb:     32      # rounded from 31.4 GiB
warning:   running on bare metal — set wantsHwVideoAccel manually
```

```
$ criomos-hw-scan --emit machine
(Machine Metal X86_64 12 [ThinkPadT14Gen5Intel] None None None 12 32)
```

The `--emit` mode prints exactly the positional nota fragment to paste
into the cluster proposal.

## Detection sources

- **`cores`** — `num_cpus` crate
- **`ramGb`** — read `/proc/meminfo` `MemTotal`, divide by 1048576,
  round to nearest GiB
- **`arch`** — `std::env::consts::ARCH` → `X86_64`/`Arm64`
- **`species`** — `Metal` by default; if `systemd-detect-virt --vm`
  exits 0, emit `Pod` and warn the operator
- **`model`** — `/sys/class/dmi/id/product_name`. Emit the raw DMI
  string; canonicalisation to "ThinkPadT14Gen5Intel" form lives in a
  small lookup table in the tool
- **`chipGen`** — extract CPU model from `/proc/cpuinfo` (via
  `procfs` crate), apply hardcoded lookup table

## chipGen lookup table

Hardcoded in the tool. Keep small (current Intel Core Ultra + recent
genrations + the legacy entries we actually see in the cluster):

```
Core Ultra * 1xxU/1xxH/1xxV   → 12  (Meteor Lake / Lunar Lake Xe-LPG)
Core i*-13xxx                 → 12  (Raptor Lake)
Core i*-12xxx                 → 12  (Alder Lake)
Core i*-11xxx                 → 12  (Tiger Lake)
Core i*-10xxx                 → 11  (Comet/Ice Lake split — be precise)
Core i*-5xxx                  →  8  (Broadwell)
```

(The "12" for Tiger/Alder/Meteor/Raptor is the iGPU media-stack gen,
which is what gates `vpl-gpu-rt`. CPU "generations" 11/12/13/14 in
Intel's marketing don't match.)

Last-updated date in a comment with link to Intel's processor naming
reference.

## v1 scope (defer everything else)

1. emit `species`, `arch`, `cores`, `model`, `chipGen`, `ramGb`
2. `--emit machine` mode prints positional `(Machine ...)` fragment
3. Intel Core Ultra + Core 11th gen and newer + Broadwell in the
   lookup
4. systemd-detect-virt for Metal vs Pod

Defer:
- ARM CPU model parsing (when first ARM node proposed)
- AMD EPYC / Threadripper / Strix Halo lookup tables
- GPU detection beyond iGPU
- Display resolution / scale (`scale_percent` field is deferred too)

## Dependencies

- `num_cpus` — CPU count
- `procfs` — parse `/proc/cpuinfo`
- `clap` — CLI args for `--emit`

No external command runtime besides `systemd-detect-virt`.

## Distribution

- Own git repo `LiGoldragon/criomos-hw-scan`
- crane + fenix flake per the canonical layout
- Used by hand: `nix run github:LiGoldragon/criomos-hw-scan` on the
  target node, then paste output into the cluster proposal
- Eventually could be invoked by the install ISO during first boot to
  pre-seed the proposal entry

## Open questions

- **Should the chipGen table live in horizon-rs instead?** Pro: one
  source of truth across criomos-hw-scan + future tools. Con: couples
  sysadmin utility to schema repo, slows table updates. **Recommend
  hardcoding in tool for v1**; revisit if a second consumer appears.
- **Should the tool also write the `node_ip`, `nordvpn`, `wifi_cert`
  bool fields?** Probably not — those are operator decisions, not
  hardware facts.
- **Should the tool detect display resolution + scale_percent?** Only
  when `display_x_pixels` etc. land in horizon — defer.
