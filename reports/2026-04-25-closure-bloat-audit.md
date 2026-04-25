# 2026-04-25 — closure bloat audit (CriomOS + CriomOS-home)

User reported the overnight `lojix build` was downloading all night.
Audited both repos for heavy packages with loose gates that could be
tightened. Two parallel sub-agents covered CriomOS modules and
CriomOS-home modules respectively.

## TL;DR

Estimated recoverable closure: **~1.5–2.5 GB** depending on node tier
and user profile. Most wins are mechanical gate tightenings; a handful
need new opt-in fields on `horizon-rs` Node/User schema.

Also note: `lojix` gave up after 15min (the hardcoded RPC_TIMEOUT in the
`lojix-auy` open bead) but `nix-daemon` kept building. This is a real
critical-path item now — we can't deploy nodes that take >15min to fetch
+ build until the timeout is lifted (or made unbounded for `build`/`switch`).

## CriomOS module audit

### HIGH wins (mechanical, no schema change)

| Module:Line | Package | Current Gate | Suggested | Savings |
|-------------|---------|--------------|-----------|---------|
| [edge/default.nix:52](modules/nixos/edge/default.nix#L52) | `evolution.enable` | `size.atLeastMin` (~all nodes) | `size.atLeastMed` + opt-in | ~250–300 MB |
| [edge/default.nix:19](modules/nixos/edge/default.nix#L19) | `gnome-control-center` (in minPackages) | `size.atLeastMin` | `size.atLeastMed` | ~100–200 MB |
| [edge/default.nix:105-111](modules/nixos/edge/default.nix#L105-L111) | GNOME services (`at-spi2-core`, `evolution-data-server`, `gnome-keyring`, `gnome-online-accounts`, `gnome-settings-daemon`) | `size.atLeastMin` | `size.atLeastMed` (only big edge nodes need full GNOME stack) | ~300–500 MB combined |
| [metal/default.nix:202-206](modules/nixos/metal/default.nix#L202-L206) | `intel-compute-runtime` + `vpl-gpu-rt` | `treatAsIntel && gpuUsesMediaDriver` (every Intel media node) | also gate on `hasVideoOutput` (skip headless Intel) | ~600 MB on headless |
| [edge/default.nix:114](modules/nixos/edge/default.nix#L114) | `tumbler.enable` | `size.atLeastMed` | also gate on `hasVideoOutput` | ~150 MB |

### MEDIUM wins (need new opt-in flag on Node)

| Module:Line | Package | Current Gate | Need | Savings |
|-------------|---------|--------------|------|---------|
| [metal/default.nix:153-169](modules/nixos/metal/default.nix#L153-L169) | `printingDriversPkgs` (`hplip`, `hplipWithPlugin`, `samsung-unified-linux-driver`, `epson-escpr*`, `gutenprint*`) | `size.atLeastMax` (every Max node — but most don't have printers nearby) | `node.wantsPrinting: bool` | ~300–500 MB |
| [edge/default.nix:51](modules/nixos/edge/default.nix#L51) | `droidcam.enable` | `size.atLeastMax` | `node.wantsWebcamBridge: bool` | ~30–50 MB |

### Already tight — leave alone

- `waydroid.enable`, `libvirtd.enable` ([metal/default.nix:518-520](modules/nixos/metal/default.nix#L518-L520)) — both behind `isLargeEdge`. Waydroid is ~2 GB, libvirtd ~100 MB. Good gate.
- `firejail.enable`, language services (Intel-specific via `chipIsIntel`).
- Core utilities (`openssh`, `ntfs3g`, `criomos-deploy`).

## CriomOS-home audit

### HIGH wins (mechanical or with one new flag)

| Module:Line | Package | Current Gate | Suggested | Savings |
|-------------|---------|--------------|-----------|---------|
| [profiles/med:116](repos/CriomOS-home/modules/home/profiles/med/default.nix#L116) | `appflowy` | `size.atLeastMin` (loose) | `size.atLeastMed` or behind `user.wantsProductivity` | ~300 MB |
| [profiles/max/default.nix:50-52](repos/CriomOS-home/modules/home/profiles/max/default.nix#L50-L52) + [profiles/max/firefox.nix](repos/CriomOS-home/modules/home/profiles/max/firefox.nix) | **firefox-bin AND chromium both installed** | `size.atLeastMax` for both | `user.preferredBrowser: "firefox" | "chromium" | "qutebrowser"` (single install) | ~400–600 MB |
| [profiles/max/default.nix:55-67](repos/CriomOS-home/modules/home/profiles/max/default.nix#L55-L67) | `obs-studio` + plugins | `size.atLeastMax` | also require `user.isMultimediaDev` | ~400 MB |
| [neovim/neovim/default.nix:124,127,185-188](repos/CriomOS-home/modules/home/neovim/neovim/default.nix#L124) | `rust-analyzer` (~600 MB), `gopls`, `hls`, `python-lsp` all-or-nothing at `size.atLeastMed`/`Max` | per-language opt-in: `user.wants.{rust,go,haskell,python,...}: bool` | ~600–1000 MB depending on user |
| [vscodium/vscodium/default.nix:114-129](repos/CriomOS-home/modules/home/vscodium/vscodium/default.nix#L114-L129) | VSCodium + AI extensions (gemini-code-assist, openai-chatgpt, claude) | `size.atLeastMed` | gate AI bundle behind `user.wantsAiAgents: bool` | ~200–400 MB |
| [emacs/emacs/default.nix:9-10,62](repos/CriomOS-home/modules/home/emacs/emacs/default.nix#L9-L10) | emacs + tree-sitter grammars (currently uses `pkdjz.mkEmacs`) | unconditional for every user | gate behind `user.preferredEditor == "emacs"` (or `user.wantsEmacs`) | ~300 MB per non-emacs user |

### MEDIUM wins

| Module:Line | Package | Current | Suggested | Savings |
|-------------|---------|---------|-----------|---------|
| [profiles/med:97-99](repos/CriomOS-home/modules/home/profiles/med/default.nix#L97-L99) | `element-desktop`, `telegram-desktop` | `size.atLeastMed` | `user.isComm` flag | ~600 MB combined |
| [profiles/max/default.nix:20](repos/CriomOS-home/modules/home/profiles/max/default.nix#L20) | `discord-ptb` | `size.atLeastMax && isMultimediaDev` | move to `user.isComm` (Discord is comm, not media) | ~320 MB |

### Already tight

- `gimp`, `krita`, `calibre` — all `size.atLeastMax && isMultimediaDev`. Good dual-gate.
- `ghc`, `clang` — properly tiered on size.
- `inkscape` — `isMultimediaDev`.

## Recommended new horizon-rs fields

Compact set, not one per package — group by capability:

### On `Node` (system)

```rust
pub wants_printing: bool,      // gates printingDriversPkgs in metal
pub wants_webcam_bridge: bool, // gates droidcam in edge
```

### On `User` (per-user)

```rust
pub preferred_browser: Browser,          // "firefox" | "chromium" | "qutebrowser" | "none"
pub preferred_editor: Editor,            // "neovim" | "emacs" | "vscodium" | "none"
pub wants_ai_agents: bool,               // VSCodium AI exts, claude/gemini/codex
pub is_comm: bool,                       // element, telegram, discord
pub wants_productivity: bool,            // appflowy and friends
pub language_focus: Vec<Language>,       // {Rust, Go, Haskell, Python, …} — gates per-lang LSPs
```

`Browser` and `Editor` enums (sum types) with serde-lowercase rename so
nix consumers see clean strings (`"firefox"`, `"emacs"`).

`Language` enum gated similarly. `language_focus` is a Vec so a user can
opt into multiple. Default: empty (no extra LSPs).

## Suggested staging

Phase A — mechanical gates (no schema change, today, ~1 GB):
1. `evolution.enable` from `size.atLeastMin` → `size.atLeastMed` in
   [edge/default.nix](modules/nixos/edge/default.nix).
2. `gnome-control-center` and the GNOME services block from
   `size.atLeastMin` → `size.atLeastMed` (same file).
3. `intel-compute-runtime` + `vpl-gpu-rt`: also require
   `hasVideoOutput` in [metal/default.nix](modules/nixos/metal/default.nix).
4. CriomOS-home `appflowy`: bump to `atLeastMed`.
5. CriomOS-home: remove the **firefox + chromium dual-install**;
   pick one default behind `size.atLeastMax`.

Phase B — add `node.wantsPrinting` + `node.wantsWebcamBridge` (small
horizon-rs change), gate the relevant `metal/edge` lines.

Phase C — `User.{preferredBrowser, preferredEditor, wantsAiAgents,
isComm, wantsProductivity, languageFocus}` (bigger horizon-rs change,
cuts ~1 GB per user once flags are set conservatively).

## Open

- **`lojix-auy` is now blocking** real deploys. The hardcoded 900s
  timeout cuts off ~all real-system fetches. Lift the timeout or make it
  unbounded for the `build`/`switch`/`deploy` actions specifically.
- The build that triggered this audit is **still running** (~8 h elapsed,
  8 active nixbld workers) despite lojix giving up — `nix-daemon` is
  long-lived. Worth letting it finish to discover the actual closure
  size and confirm the audit numbers.
