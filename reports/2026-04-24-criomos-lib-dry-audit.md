# 2026-04-24 — criomos-lib + DRY audit + mkJsonMerge alternatives

Three parallel audits triggered by the question: *now that horizon-rs
owns projection, what nix code is obsolete or duplicating logic?*

## 1. `lib/default.nix` — what's still load-bearing

| Helper | Callsites | Verdict |
|--------|-----------|---------|
| `lowestOf` | 0 | **DROP** — unused |
| `highestOf` | 0 | **DROP** — unused (and the impl is buggy: `tail` of a sorted list returns all-but-first, not the largest) |
| `callWith` | 0 | **DROP** — unused; modern nix prefers explicit destructure |
| `importJSON` | 1 ([CriomOS-home/modules/home/profiles/min/default.nix:65](repos/CriomOS-home/modules/home/profiles/min/default.nix#L65) — Zed colemak keymaps) | **KEEP** — trivial wrapper, used |
| `mkSizeAtLeast` | 0 direct (only called by `matchSize`) | **DROP** — duplicates `Magnitude::ladder()` in horizon-rs |
| `matchSize` | 1 ([CriomOS-home/modules/home/profiles/min/sway.nix:43](repos/CriomOS-home/modules/home/profiles/min/sway.nix#L43)) | **INLINE** — single callsite; rewrite as `if size.atLeastMed then ... else ...` |
| `mkJsonMerge` | 3 ([vscodium](repos/CriomOS-home/modules/home/vscodium/vscodium/default.nix#L164), [med profile mentci-cli](repos/CriomOS-home/modules/home/profiles/med/default.nix#L183), legacy) | **KEEP — but it's broken**: see §3 |

**Net result**: `lib/default.nix` shrinks from 78 lines to ~30. We end
up with `{ importJSON, mkJsonMerge }` only.

## 2. DRY violations — nix code that should be horizon-rs derived fields

### HIGH (multi-file or complex-conjunction)

| Pattern | Sites | Proposed horizon-rs field |
|---------|-------|---------------------------|
| `size.atLeastMax && behavesAs.edge` (CUDA / Waydroid / libvirtd / 32-bit graphics) | [metal:32](modules/nixos/metal/default.nix#L32), [metal:520](modules/nixos/metal/default.nix#L520), [edge:34](modules/nixos/edge/default.nix#L34) | `node.isLargeEdge: bool` |
| `size.atLeastMin && !behavesAs.iso && !behavesAs.center && !behavesAs.router` (NetworkManager enable) | [normalize:128](modules/nixos/normalize.nix#L128) | `node.enableNetworkManager: bool` |
| Three lid-switch policies derived from `behavesAs.{center,edge,lowPower}` | [metal:453-458](modules/nixos/metal/default.nix#L453-L458) | `node.handleLidSwitch{,ExternalPower,Docked}: enum` |

### MEDIUM (single-file but pure projection)

| Pattern | Site | Proposed field |
|---------|------|----------------|
| `extraGroups` ladder built from `trust.atLeast{Med,Max}` + sway-enable | [users.nix:33-48](modules/nixos/users.nix#L33-L48) | `user.extraGroups: [String]` |
| `linger = trust.atLeastMax && behavesAs.center` | [users.nix:50](modules/nixos/users.nix#L50) | `user.enableLinger: bool` |

### LOW (single-use magic strings; do later)

| Pattern | Site | Proposed |
|---------|------|----------|
| Terminal font picked from `size.atLeastMed` | [profiles/min:62](repos/CriomOS-home/modules/home/profiles/min/default.nix#L62) | `user.terminalFontFamily: String` |
| Editor command picked from `size.atLeastMed` | [neovim:328](repos/CriomOS-home/modules/home/neovim/neovim/default.nix#L328) | `user.editorCommand: String` |

### Already DRY (no action — flagged for sanity)

`isBuilder` in [nix.nix](modules/nixos/nix.nix) — already precomputed by
horizon-rs as `node.isBuilder`; nix.nix correctly just consumes it.

## 3. `mkJsonMerge` is broken — the `jq -s '.[0] * .[1]'` is **shallow**

The current implementation uses jq's `*` operator at top level, which
**replaces nested objects wholesale**. So if nix declares
`{ "[python]": { tabSize = 4; } }` and the user has
`{ "[python]": { wordWrap = "on"; } }`, the user's `wordWrap` is
silently lost.

Options researched (rough cost/benefit):

| Opt | Approach | Trade-off |
|-----|----------|-----------|
| **A** | jq with custom recursive `deepmerge()` function | Keep current shape; ~10 lines of jq adds true deep merge. Lowest friction. |
| **B** | yq `'. as $i \| reduce ({}; . * $i)'` (multiply operator) | Recursive by default; same shell-out shape; adds `yq` dep. |
| **C** | Move merge to nix-eval time via `lib.recursiveUpdate` | No runtime jq, but **defeats the "preserve user edits" goal** — would need user changes to round-trip via nix. Skip. |
| **D** | VSCode-specific: split managed vs user via `User/settings.json` + `Workspace/settings.json` | Editor merges natively; zero shell-out. Only works for VSCodium, not the mentci-cli MCP file. |
| **E** | jsonnet `std.mergePatch` at nix-eval time | Adds jsonnet dep; same fundamental problem as C. |

**Recommendation**:
- **For VSCodium**: option D (let VSCode handle precedence via
  `User/settings.json` for managed defaults; user edits go to a
  workspace settings file or a sibling). Zero merge code.
- **For everything else** (mentci-cli MCP, future config files):
  option A (jq deepmerge function) — keeps the helper shape but fixes
  the actual bug.

If we don't want to maintain the jq function, an external tool that's
already in nixpkgs and does true deep merge would be cleaner — agent
suggests **yq** (option B). One dep, well-documented operator.

## Proposed execution order

1. **Drop dead helpers** (`lowestOf`, `highestOf`, `callWith`,
   `mkSizeAtLeast`). Inline the one `matchSize` callsite. ~10 min.
2. **Implement HIGH-tier horizon-rs fields** (`isLargeEdge`,
   `enableNetworkManager`, `handleLidSwitch*`). Then sed-replace nix
   sites. ~1 hour, with `lojix eval` regression each.
3. **Implement MEDIUM-tier fields** (`user.extraGroups`,
   `user.enableLinger`). Same loop. ~30 min.
4. **Fix `mkJsonMerge`**: pick option A or B. Either way, also add a
   regression test (round-trip a `{ a: { b: 1 } }` overlay against
   `{ a: { c: 2 } }` user file → expect `{ a: { b: 1, c: 2 } }`).
5. **LOW-tier**: defer until the relevant module is touched again.

After all of this, `lib/default.nix` ends with just `importJSON` +
(possibly external) JSON merge — and ~5 lines of horizon-rs Rust per
moved field replace ~30 lines of nix conditionals across consumer
files.

## Open questions

- **Q1**: Do we want `user.extraGroups` to be a flat list, or split as
  `user.extraGroupsBaseline` + `user.extraGroupsTrustMed` + `…Max` so
  a consumer can compose? Flat list is simpler; composition gives more
  flexibility. Lean: flat.
- **Q2**: For `node.handleLidSwitch*` — should this be a string enum
  (`"ignore" | "suspend" | "lock"`) or a richer struct? The systemd
  options are well-defined strings; lean: string enum.
- **Q3**: VSCodium settings split (option D) — is the `User/` vs
  `Workspace/` distinction acceptable, or do you want all settings in
  one file?
- **Q4**: Worth a small unit test in horizon-rs covering the new
  derived fields, or trust the integration via `lojix eval`?
