# 2026-04-24 — post-compact infra audit

Fresh audit across CriomOS, CriomOS-home, horizon-rs, lojix, goldragon
after the prior-session compact. Three parallel sub-agents each surveyed
one slice; this report aggregates their findings into a single picture,
flags **inconsistencies**, and lists **open questions**.

Context fix applied this session: `.claude/settings.json` was missing in
CriomOS (mentci-next has it). Added `PreCompact` + `SessionStart` hooks
calling `bd prime` so context recovery is automatic going forward.

## Where we are — the good news

### CriomOS (6/21 modules wired)

Wired + proven end-to-end (all 6 goldragon nodes produce real drvPaths):

```
imports = [ ./disks/preinstalled.nix ./normalize.nix ./nix.nix
            ./complex.nix ./llm.nix ./users.nix ];
```

Unwired readiness (18 remaining):

| Tier | Count | Modules |
|------|-------|---------|
| **GREEN** (wire as-is) | 11 | `network/{unbound, yggdrasil, headscale, tailscale, networkd, wifi-eap, wireguard}`, `router/{wifi-pki, yggdrasil}`, `disks/{liveiso, pod}`, `edge/default`, `userHomes` |
| **YELLOW** (small fix) | 3 | `network/default` (aggregator), `router/default`, `metal/default` |
| **RED** (broken on import) | 2 | `network/trust-dns`, `network/nordvpn` |

### horizon-rs

Mg struct refactor is fully propagated across [lib/src/](../../../horizon-rs/lib/src/)
— `node.rs`, `user.rs` expose `Mg { value, is }`; machine/io hold no
magnitudes so untouched; JSON serde emits nested camelCase
(`{value: "Med", is: {min, med, max}}`). No stale bare-`Magnitude` field
accesses found.

### lojix

All five CLI actions (`eval`, `build`, `switch`, `boot`, `test`) are
implemented in [src/main.rs](../../../lojix/src/main.rs). Cache layout
`~/.cache/lojix/{horizon,system}/...` is content-addressed; works across
runs.

### goldragon

[datom.nota](../../../goldragon/datom.nota) parses cleanly, lists the 6
live nodes (balboa, klio, ouranos, prometheus, tiger, zeus), no xerxes,
no stray legacy `.nix` files.

### CriomOS-home

All 7 home modules (base, neovim, vscodium, profiles/{min,med,max}, emacs)
have been ghost-arg-cleaned and flattened **except** `emacs/emacs/default.nix`
which still takes `pkdjz` and calls `mkEmacs`. Blocker is the
CriomOS-emacs split.

## Inconsistencies

### I1. `typeIs` vs `behavesAs` — schema drift

[modules/nixos/metal/default.nix](../modules/nixos/metal/default.nix)
and [modules/nixos/router/default.nix](../modules/nixos/router/default.nix)
reference `horizon.node.typeIs.{edge, ...}`, but every wired module
(`normalize`, `llm`, `edge`, etc.) uses `horizon.node.behavesAs.{center, router, edge, iso, bareMetal, lowPower}`. `typeIs` is **not** in the
horizon-rs schema.

**Likely cause**: stale rename that missed these two files when
`.methods.typeIs` was flattened.

**Fix**: `s/typeIs/behavesAs/` in both files, re-test.

### I2. `network/trust-dns.nix` references undefined symbols

- Line 12: `criomeDomainName` used but never inherited
- Line 65: `toFormatFile(...)` — function doesn't exist in scope or in
  `pkgs.formats`

**Likely cause**: module was half-migrated from an older layer (probably
`pkdjz.toFormatFile` or similar).

**Question Q1**: does this module need to exist at all, or was it
superseded by `network/unbound.nix`? If alive, what was `toFormatFile`
originally — `pkgs.formats.toml.generate`?

### I3. `network/nordvpn.nix` hardcoded data path

Line 19: `lockPath = ../../../data/config/nordvpn/servers-lock.json`
is a relative path pointing outside `modules/`. Resolves from the flake
root, but is fragile if the module moves.

**Fix option A**: expose the path as a `constants` entry.
**Fix option B**: leave it — other wired modules (`normalize`, `llm`) use
relative paths the same way.

### I4. goldragon lags Mg shape — by design?

`datom.nota` emits bare magnitudes (`Min`, `Med`, `Max`) — the Mg bundle
is constructed at projection time in `horizon-rs` via `Mg::from(mag)`.
JSON output is Mg-shaped; nota input is bare-shaped.

**Question Q2**: is this the intended invariant (nota = proposal =
concise, json = projection = rich)? If so, it's a clean separation and
should be written down somewhere. Right now no doc captures it.

### I5. `lojix-auy` P0 "stream subprocess output" — audit disagrees with bead

Sub-agent read lojix and reported "subprocess output is NOT buffered —
uses `Command::output()` directly". But `Command::output()` **is** the
buffered path — it blocks until the child exits, then returns all
stdout/stderr. The bead was filed precisely because long-running
`nix build` / `nixos-rebuild` invocations appear to hang (no
intermediate output visible).

**Question Q3**: is `lojix-auy` still valid, or has streaming been
implemented somewhere the agent didn't look (e.g. an `io` actor wrapping
the child)? Needs human-verification against the running behaviour.

### I6. `lojix-cv1` P0 "atomic artifact materialization" — status unclear

Sub-agent reports `HorizonDir::write()` writes JSON + flake.nix then
computes NAR hash, "appears atomic". But *atomic* in the filesystem
sense means rename-into-place after a full write, so a crash mid-write
can't leave a partially-populated cache entry. Needs direct code read.

**Question Q4**: does the write use `tempfile` + `persist()` (atomic
rename) or is it direct `File::create` + write (non-atomic)? If the
latter, bead stays P0.

### I7. CriomOS-home aggregate is a stub

[modules/home/default.nix](../../../CriomOS-home/modules/home/default.nix)
currently only conditionally imports `inputs.niri-flake.homeModules.config`.
All 7 wire-ready home modules are clean but the aggregate never pulls
them in.

**Question Q5**: wire this incrementally the same way CriomOS Phase 8
has been wiring `criomos.nix` (one import at a time, test, commit)? The
equivalent of `lojix eval` for home-manager would be a standalone
`home-manager switch --flake ...#li@ouranos` invocation, but the flake
doesn't yet export a `homeConfigurations.*`. Should we add one tiny
test configuration to close the feedback loop, or wait for full
`userHomes.nix` integration to test via `lojix eval`?

### I8. Blueprint auto-discovery nesting quirk

Editor modules live at `modules/home/emacs/emacs/default.nix` (two-deep),
not `modules/home/emacs/default.nix` (flat). Blueprint expects flat. `nix
flake show` prints a warning. Not a runtime blocker (imports use relative
paths) but surprising.

**Question Q6**: flatten to `modules/home/emacs/default.nix` (small
refactor), or add a blueprint shim `modules/home/emacs/default.nix`
that re-exports `./emacs/default.nix`, or document and ignore?

## Open questions rolled up

| ID | Topic | What's needed |
|----|-------|---------------|
| Q1 | `trust-dns` fate | keep/delete? if keep, identify `toFormatFile` |
| Q2 | nota=bare, json=Mg invariant | confirm + document |
| Q3 | lojix streaming output | verify behaviour, keep/close `lojix-auy` |
| Q4 | lojix write atomicity | read code directly, keep/close `lojix-cv1` |
| Q5 | CriomOS-home wiring strategy | incremental vs big-bang; test harness shape |
| Q6 | Blueprint emacs/emacs nesting | flatten vs shim vs document |
| Q7 | `Mg.is` vs `Mg.atLeast` naming | decide bead `CriomOS-c5z` |

## Recommended next steps (in order)

1. **Easy win**: fix I1 (`typeIs` → `behavesAs` in metal + router) and
   wire `./metal/default.nix` + `./router/default.nix`. Probably an hour
   of test-and-fix.
2. **Bundle**: wire the 11 GREEN modules in a loop
   (`network/{…}`, `disks/{liveiso, pod}`, `edge/default`, `userHomes`).
   Same one-at-a-time pattern per
   [reference_module_wire_pattern.md](../../.claude/projects/-home-li-git-CriomOS/memory/reference_module_wire_pattern.md).
3. **Investigate RED**: I2 (trust-dns) — decide keep vs delete before
   wiring.
4. **Parallel track**: answer Q5 and start wiring home modules into
   `CriomOS-home/modules/home/default.nix`.
5. **Lojix audit**: Q3 + Q4 directly from source to confirm or close
   `lojix-auy` / `lojix-cv1`.

## Notes on session hook fix

`.claude/settings.json` now present at `/home/li/git/CriomOS/.claude/settings.json`
with:

```json
{
  "hooks": {
    "PreCompact":   [{"hooks": [{"command": "bd prime", "type": "command"}], "matcher": ""}],
    "SessionStart": [{"hooks": [{"command": "bd prime", "type": "command"}], "matcher": ""}]
  }
}
```

Same content as [mentci-next/.claude/settings.json](../../../mentci-next/.claude/settings.json).
