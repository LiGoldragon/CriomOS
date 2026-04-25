# home-tcj wire-up attempt + CriomOS-home bloat audit

## TL;DR

Attempted to wire `CriomOS-home/modules/home/default.nix` aggregate
(the `home-tcj` P1 bead). Surfaced a **deeper architecture issue**
that blocks end-to-end home-manager wiring, plus **years of stale
input references** that are pure cleanup. Architecture issue is
filed for follow-up; cleanup landed; aggregate reverted to stub
state pending the architecture fix. Bloat audit results captured.

## Architecture issue: consumer-passed inputs vs CriomOS-home's own inputs

**Symptom**: every attempted wire-up of base/profiles/editors fails
with one of:
- `attribute 'pi-mentci' missing` (consumer doesn't have it)
- `option 'programs.pi-mentci' does not exist` (homeModule not imported)
- `option 'stylix.base16Scheme' does not exist` (stylix homeModule not imported)
- Stale references to `inputs.{codex-cli, mentci, aski, vscode-aski}`
  which aren't declared in any flake.

**Root cause**: home modules read `inputs.<X>` for inputs that are
declared in CriomOS-home's own `flake.nix` (stylix, niri-flake,
noctalia, pi-mentci, mentci-tools, nix-vscode-extensions). But
consumers (CriomOS userHomes.nix) pass their own `inputs` via
`extraSpecialArgs`. CriomOS-home's flake inputs are not visible to
its own home modules through that channel.

**`mkIf` doesn't help** — the module system validates option paths
exist regardless of `mkIf` condition. `programs.pi-mentci = mkIf
false { ... }` still errors because `programs.pi-mentci` option
isn't defined. Same for `stylix.X`, etc. Conditional gates only work
for *option values*, not *option-path existence*.

**Proper fix**: have CriomOS-home's `homeModules.default` inject its
own inputs at flake level (and import the upstream homeModules for
stylix/noctalia/pi-mentci/etc that those refs depend on). Pattern
sketch:

```nix
# CriomOS-home/flake.nix (sketch, not implemented)
outputs = inputs: inputs.blueprint { inherit inputs; } // {
  homeModules.default = { ... }: {
    imports = [
      ./modules/home  # the actual aggregate
      inputs.stylix.homeModules.stylix
      inputs.niri-flake.homeModules.config
      inputs.noctalia.homeModules.default
      # …pi-mentci etc when they expose homeModules
    ];
    _module.args = {
      criomosHomeInputs = inputs;  # disambiguate from consumer inputs
    };
  };
};
```

Then home modules read `criomosHomeInputs.X` instead of `inputs.X`.

**Effort**: roughly half a day. Touches CriomOS-home/flake.nix +
every consumer of `inputs.X` in home modules.

## What landed (cleanup pass)

Wire-up attempt surfaced a pile of stale references — these were
clearly broken before, just nobody had triggered them:

### Stale inputs not declared anywhere
- [profiles/min:204](repos/CriomOS-home/modules/home/profiles/min/default.nix#L204): `inputs.codex-cli` — dropped from AIPackages
- [profiles/med:138,177,186](repos/CriomOS-home/modules/home/profiles/med/default.nix): `inputs.mentci` — dropped (mentci-codium package + xdg desktop entry + `home.activation.mergeMentciMcp`)
- [vscodium/vscodium:39,45](repos/CriomOS-home/modules/home/vscodium/vscodium/default.nix): `inputs.aski` + `inputs.vscode-aski` — dropped vscode-aski extension + askiWasm helper

### Broken cross-repo data-file paths
- [profiles/min:37-38](repos/CriomOS-home/modules/home/profiles/min/default.nix#L37): `largeAIConfigPath = ../../../data/config/largeAI/llm.json` — resolves out of CriomOS-home; the file lives in CriomOS. Stubbed to `{ models = [{}]; serverPort = 0; }`.
- [profiles/min:53](repos/CriomOS-home/modules/home/profiles/min/default.nix#L53): `colemakZedKeys = criomos-lib.importJSON ./../../../data/ZedKeymaps/goldragon-colemak.json` — file doesn't exist anywhere. Stubbed to `{}`.

### Schema drift
- [profiles/min](repos/CriomOS-home/modules/home/profiles/min/default.nix): `node.typeIs.largeAI`, `node.typeIs."largeAI-router"`, `node.behavesAs.largeAI` — current schema is `largeAi` (lowercase i). Block stubbed entirely.

### Scope error
- [neovim/neovim:101](repos/CriomOS-home/modules/home/neovim/neovim/default.nix#L101): `with vimPlugins` — should be `with aolPloginz`. Fixed.

### Now-unused after cleanup
- `inputs`, `criomos-lib.mkJsonMerge`, `system` args/bindings in profiles/med
- `largeAIModels` binding in profiles/min

All pushed in incremental commits to `LiGoldragon/CriomOS-home`.

## Bloat audit findings (sub-agent, 2026-04-25)

Categorical findings to triage when you decide what to drop:

### Suspected unused / heavy

| Module | Package | Note |
|---|---|---|
| profiles/min | `gemini-cli`, `codex`, `opencode`, `llama-cpp` (in `AIPackages`) | All AI CLIs — likely overlap with VSCodium AI extensions + aider |
| profiles/min | `aspell` (alongside `hunspell`) | Spell-check duplication — drop aspell |
| profiles/med | `spotify-player` | Spotify TUI; check if used |
| profiles/med | `ledger-live-desktop` (~300 MB) | Crypto wallet; check if used |
| profiles/med | `sbcl` (~200 MB) | Common Lisp; only if active Lisp dev |
| profiles/med | `element-desktop` (~500 MB) | Matrix client; you have `dino` for XMPP in min |
| profiles/med | `telegram-desktop` (~200 MB) | Verify use |
| profiles/max | `calibre` (~800 MB) | E-book manager |
| profiles/max | `gitkraken` (~200 MB) | Git GUI; lazygit + VSCode SCM cover |
| profiles/max | `bottles` (~200 MB) | Wine/Windows emulation |
| profiles/max | `lapce` (~200 MB) | Code editor; redundant with VSCode + neovim |
| profiles/max | `obs-studio + plugins` (~400 MB+) | Verify if streaming/recording is active |
| profiles/max | `google-chrome` (~300 MB) | You have qutebrowser + chromium variants — pick one |
| neovim/max | `ghc + cabal-install + stack` (~1.6 GB combined) | Haskell toolchain — install ad-hoc when needed |
| neovim/max | `haskell-language-server` (~1 GB+) | Couples to ghc decision |

### Already dropped this session
- `discord-ptb`, `firefox-bin` (profiles/max)
- `appflowy` (profiles/min)
- `firejail` (CriomOS edge)
- intel-compute-runtime (CriomOS metal)
- LLM models on non-LargeAi nodes (CriomOS llm.nix gated)

### Conservative cleanup target
Dropping the spell-check duplication + AI CLIs + ghc toolchain +
calibre + element + bottles + gitkraken would shave **~3 GB** from a
fully-wired user closure (will be measurable once the architecture
fix lands and home-manager actually has profile content).

## Recommended next steps

1. **Architecture fix** in CriomOS-home flake: inject own inputs at
   `homeModules.default` level + import upstream homeModules for
   stylix/noctalia/etc. ~½ day. Unblocks home-tcj.
2. **After step 1**: re-attempt wire-up. Re-run `lojix eval` per
   node. Build ouranos to measure actual closure delta.
3. **Triage bloat audit**: pick which packages from the table above
   to drop. Each drop is a one-line change in the relevant profile.
4. **Restore `programs.pi-mentci` + `inputs.mentci-tools` usages**
   once architecture allows — these ARE legitimate.

## Status of touched repos

- **CriomOS-home**: 7 commits this session — broken-input cleanups +
  stub-outs + aggregate revert. Net: aggregate is back at stub
  state, but the cleanup is permanent and useful.
- **CriomOS**: nothing touched in this report's scope.

## Honest note

The home-tcj bead **stays open** after this session. What landed is
hygiene that needed doing anyway; what was hoped (end-to-end home
profile activation) is blocked on the architecture fix.
