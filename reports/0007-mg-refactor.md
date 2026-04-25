# 2026-04-24 — `Mg` refactor (Magnitude bundled with its ladder)

Schema change in horizon-rs and downstream renames in CriomOS +
CriomOS-home. Moves trust/size predicate logic from consumer Nix
modules into horizon-rs (canonical location).

## What changed

`Node.{size,trust}` and `User.{size,trust}` were `Magnitude` (a
plain enum). They are now `Mg`:

```rust
pub struct Mg {
    pub value: Magnitude,   // raw enum: None | Min | Med | Max
    pub is: AtLeast,        // { min, med, max } booleans, monotonic
}
```

The former separate fields `Node.sized_at_least` and the just-added
`Node.trust_at_least` / `User.trust_at_least` are **dropped** —
superseded by `size.is` and `trust.is`.

## Consumer Nix shape

```
horizon.node.size.value        # "None" / "Min" / "Med" / "Max"
horizon.node.size.is.min       # true when size >= Min
horizon.node.size.is.med       # true when size >= Med (= Med OR Max)
horizon.node.size.is.max       # true when size == Max

horizon.node.trust.is.max      # true when trust == Max
horizon.users.li.trust.is.med  # true when user li's trust >= Med
```

Semantics are at-least (monotonic) — same as the old `sizedAtLeast.X`
behavior. `is.med` fires for both `Med` and `Max`.

The new Nix idiom is `inherit (horizon.node) size; … size.is.med`.
Old idiom was `inherit (horizon.node) sizedAtLeast; … sizedAtLeast.med`.
Mechanical rename.

## Why bundle

Three reasons:

- **Consumer ergonomics.** Reads as English: `node.size.is.med` =
  *is the size at the med rung?*
- **One field per concept.** Magnitude and its ladder are facets of
  the same value; bundling them into `Mg` matches "one type per
  concept" (Mentci style) better than two parallel sibling fields.
- **Drop boilerplate at consumers.** Before this refactor, `users.nix`
  needed an inline `magnitudeRank = m: { None=0; Min=1; … }.${m}`
  helper to compare trust ordinally. Per directive, that logic
  belongs in horizon-rs. With `Mg`, `users.nix` just does
  `trust.is.med` directly.

## Pending: `is` vs `atLeast`

Open question: the field name `is` is concise but a little terse.
`atLeast` is more explicit — `node.size.atLeast.med` reads as the
predicate it actually computes. Tracked: see open question at end
of this report.

## Files touched

**horizon-rs:**
- [lib/src/magnitude.rs](../repos/horizon-rs/lib/src/magnitude.rs) — added `Mg` struct + `Mg::from(Magnitude)`.
- [lib/src/node.rs](../repos/horizon-rs/lib/src/node.rs) — `Node.size`, `Node.trust` typed as `Mg`. Dropped `sized_at_least` and `trust_at_least` fields. Construction uses `Mg::from(self.size)` etc. Internal `matches!(u.trust, Magnitude::Max)` updated to `matches!(u.trust.value, Magnitude::Max)` because `u.trust` is now `Mg`.
- [lib/src/user.rs](../repos/horizon-rs/lib/src/user.rs) — `User.size`, `User.trust` typed as `Mg`. Dropped derived `sized_at_least`. Construction uses `Mg::from(...)`.

**lojix:**
- [Cargo.lock](../repos/lojix/Cargo.lock) — bumped horizon-lib to the post-Mg commit.

**CriomOS** (sed two-pass `sizedAtLeast.X → size.is.X` then `sizedAtLeast → size`):
- normalize.nix, nix.nix, edge/default.nix, metal/default.nix, users.nix
- `users.nix` additionally rewritten — replaced the old
  `magnitudeRank` helper + `(trust > 0)` style with
  `trust.is.{min,med,max}`.

**CriomOS-home** (same sed pass):
- vscodium/vscodium/default.nix, neovim/neovim/default.nix
- profiles/{max,med}/default.nix, profiles/med/{qutebrowser,mentci-cli}.nix
- profiles/min/{default,sway}.nix

## Verification

After the refactor, `lojix eval --cluster goldragon --node X` on
all 6 nodes (balboa, klio, ouranos, prometheus, tiger, zeus) still
produces real toplevel drvPaths. No regression.

## Migration cookbook (if more code needs rewriting)

- `inherit (horizon.node) sizedAtLeast` → `inherit (horizon.node) size`
- `sizedAtLeast.med` → `size.is.med`
- `inherit (user) trust` (then `trust >= 2`) → still
  `inherit (user) trust` but use `trust.is.med`
- raw magnitude comparison (`x == "Max"`) → `x.value == "Max"` if
  `x` is now `Mg`, else unchanged

## Open question

**Rename `is` → `atLeast`?** Two arguments:

- *for*: `size.atLeast.med` reads more explicitly as a predicate;
  matches the rust struct `AtLeast`'s name; less likely to be
  misread by someone scanning the code quickly.
- *against*: `size.is.med` is shorter and reads naturally as English
  ("is med"); the field is exactly what `is` would mean colloquially.

Filed as bead. Decision pending.
