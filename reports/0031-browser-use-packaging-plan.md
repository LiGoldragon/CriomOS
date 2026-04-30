# browser-use → CriomOS-home packaging plan

Pre-implementation research + smoke test for adding [browser-use](https://github.com/browser-use/browser-use)
to CriomOS-home so agents can drive the hexis-managed Chrome
(CDP exposed at `127.0.0.1:9222` once gen 80 is live).

## TL;DR

- browser-use **works** against an existing Chrome via CDP — verified
  in a temp uv venv against a headless Chrome we spawned ourselves.
  See [Smoke test](#smoke-test).
- Packaging path: **`uv2nix` / `pyproject.nix-uv`** with our own thin
  `pyproject.toml` that depends on `browser-use`. The dep tree is 264
  packages; hand-rolled `buildPythonApplication` is not viable.
- Closure size will be substantial (rough estimate 500 MB – 1 GB,
  given Pillow/numpy/pyobjc-free side, but reportlab + lots of LLM
  SDKs). This is a real cost — flag for sign-off before landing.
- Profile tier: **Large** (matches Chrome's tier in
  `modules/home/profiles/max/default.nix`, `mkIf size.atLeastLarge`
  block). Only systems that have Chrome should ship its driver.
- Open question for Li before implementation: do we want CLI only,
  library env only, or both? See [Surface decisions](#surface-decisions).

## What browser-use is, in one paragraph

A Python library + CLI ([latest 0.12.6, 2026-04](https://pypi.org/project/browser-use/))
that wraps Chrome DevTools Protocol with an a11y-tree-snapshot loop
designed for LLM agents. Mainstream choice in early 2026 (89.1 % on
WebVoyager). They [migrated off Playwright to direct CDP via their
own `cdp-use` client](https://browser-use.com/posts/playwright-to-cdp)
in 2025. Library-first usage: `from browser_use import Agent,
BrowserSession, BrowserProfile`. CLI for one-shot interactive runs.

## Smoke test

Done in `/tmp/bu-test/` against a self-spawned headless Chrome
(`google-chrome --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-bu-test --headless=new`):

- `nix shell nixpkgs#uv` → `uv init --bare` → `uv add browser-use`:
  resolved + downloaded fine. **264 locked transitive packages**
  (`uv.lock` weighs in at 4573 lines). Resolution time ~30 s.
- `python -c "from browser_use import Agent, BrowserSession"`: clean
  import, no missing system libs at the Python level.
- `BrowserSession(browser_profile=BrowserProfile(cdp_url="http://127.0.0.1:9222"))`
  → `await session.start()` connected to the live Chrome cleanly:
  `INFO [BrowserSession] Setting viewport to 1920x1080`. Then a
  websocket close + auto-reconnect cycle kicked in
  (`WARNING 🔌 CDP WebSocket message handler exited unexpectedly … 🔄
  WebSocket reconnected after 0.1s (attempt 1)`); we killed the
  script before the next API step ran. The reconnect was probably my
  smoke script's fault (using `get_current_page()` / `page.goto()`
  shapes that don't match 0.12), not packaging-relevant. Will re-test
  with the real API surface once installed for real.

The packaging-relevant findings: install path works, CDP attach
works, no surprise FFI / build-time deps surfaced.

## Why hand-rolled `buildPythonApplication` is not viable

The current Python precedent in this ecosystem is
[`mentci-tools/packages/linkup.nix`](https://github.com/LiGoldragon/mentci-tools/blob/main/packages/linkup.nix):
`pkgs.python3.pkgs.buildPythonApplication` with `dependencies = with
python.pkgs; [ httpx pydantic ]` — 2 deps, all in nixpkgs.

For browser-use:

- **Missing from nixpkgs entirely**: `cdp-use`, `bubus`, `uuid7`,
  `browser-use-sdk`. Each would need its own
  `buildPythonPackage` recipe, vendored into our repo.
- **Pinned mismatches with nixpkgs**: `posthog` (need 7.7, have
  7.11), `openai` (need 2.16, have 2.31), `anthropic` (need 0.76,
  have 0.94). Each would need a per-package version override
  (`overridePythonAttrs` with a different `fetchPypi` hash and
  potentially patched build-system).
- **Total dep tree**: 264 packages. Hand-maintaining this would be a
  full-time job and would drift on every browser-use bump.

So: lockfile-driven packaging is mandatory. Two production-grade
tools in 2026:

- **[`pyproject.nix` + `uv2nix`](https://github.com/pyproject-nix/uv2nix)** —
  current best-practice. Consumes a `uv.lock`, produces nixpkgs-style
  Python derivations. Active, maintained by the pyproject-nix org.
- **[`poetry2nix`](https://github.com/nix-community/poetry2nix)** —
  older, requires a `poetry.lock`. Browser-use uses Hatchling not
  Poetry, so we'd be authoring a Poetry shim project either way.
  uv is the better fit.

Recommendation: **`uv2nix`** (with `pyproject-nix.lib` for the build
backend). Add as a CriomOS-home flake input.

## Implementation shape

Lay out a small Python project under `packages/browser-use/`:

```
packages/browser-use/
├── pyproject.toml      # one-liner: dependencies = ["browser-use"]
├── uv.lock             # generated: uv lock --python 3.13
└── default.nix         # uv2nix wiring: build a python env with browser-use
```

`default.nix` (sketch — needs verification against current uv2nix API):

```nix
{ pkgs, inputs, ... }:
let
  python = pkgs.python313;
  workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
  pythonSet = (pkgs.callPackage inputs.pyproject-nix.build.packages {
    inherit python;
  }).overrideScope (lib.composeManyExtensions [
    inputs.pyproject-build-systems.overlays.default
    overlay
  ]);
in
pythonSet.mkVirtualEnv "browser-use-env" workspace.deps.default
```

Then in `modules/home/profiles/max/default.nix` (the same
`mkIf size.atLeastLarge` block where Chrome lives, since browser-use
without Chrome is useless):

```nix
home.packages = [
  # ...
  (pkgs.callPackage ../../../../packages/browser-use { inherit inputs; })
];
```

This puts `browser-use` (CLI) on PATH, alongside the Python env's
`bin/python` if we expose it.

## Surface decisions (need Li's call)

1. **CLI only, library env only, or both?** browser-use ships both a
   `browser-use` CLI and an importable `browser_use` library.
   - **CLI only** — simplest: `home.packages = [ <env>/bin/browser-use only ]`.
     Agents call `browser-use --task "..."`. Loses the ability to write
     custom Python scripts using the library.
   - **Library env on PATH** — expose the whole venv's `bin/python` as
     `browser-use-python` or similar. Agents do `browser-use-python
     script.py`. Most flexible, slightly uglier.
   - **Both** — recommended. Same env, two entry points.

2. **LLM API key wiring.** `linkup` uses gopass at exec time:
   `LINKUP_API_KEY="${LINKUP_API_KEY:-$(gopass show -o linkup.so/api-key)}"`.
   browser-use accepts `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` /
   `GOOGLE_API_KEY`. Likely want a similar wrapper that reads from
   gopass (`anthropic.com/api-key` etc.) before exec.

3. **Profile tier.** Chrome wrap is gated by `mkIf size.atLeastLarge`
   in `max/default.nix`. browser-use should be gated identically —
   shipping it on Min/Med where Chrome isn't installed is wasted
   closure. Confirms: gate at `atLeastLarge`.

4. **Closure cost.** 264 packages → estimate 500 MB – 1 GB closure.
   This is real. Alternatives if too expensive:
   - **Don't package at all; `nix run` on demand.** A separate flake
     output `packages.browser-use` users invoke as `nix run
     .#browser-use --` when needed. No installation, no closure cost
     to the system. Loses tab-completion, makes the tool discoverable
     only via convention.
   - **Rust alternative ([chromiumoxide](https://github.com/mattsse/chromiumoxide))**:
     write our own thin agent loop. Lower closure, but real
     development effort. Not recommended unless browser-use turns out
     to be wrong-shape for us.

## Anti-patterns checked

Per `lore/nix/basic-usage.md` and CriomOS `AGENTS.md`:

- ✅ No `pip install` / `cargo install` / `npm install -g` —
  uv2nix produces a pure Nix derivation.
- ✅ No raw `/nix/store/...` paths in conversation/files.
- ✅ No `<nixpkgs>` / `NIX_PATH` use — flake inputs only.
- ✅ Crate-free (this is Python, not Rust; not subject to the
  "no Rust crates in CriomOS" rule, and CriomOS-home explicitly
  hosts pkg derivations of this shape).
- ⚠️ FOD / IFD: uv2nix uses fixed-output sources (lockfile pins
  hashes); not IFD. Safe.
- ⚠️ `programs.chromium.package` is already wrapped via
  `inputs.hexis.lib.wrapWithHexis`; browser-use is *additive* (a
  separate package), so the wrap is unaffected.

## Risks & open issues

- **API drift.** browser-use 0.x is fast-moving. Whatever lockfile
  we pin will need periodic refreshing (`uv lock --upgrade`). Cost:
  ~5 min per bump.
- **websocket reconnect** observed in smoke test — to re-test once
  packaged with the real API surface (post-reboot, against the
  hexis-seeded Chrome rather than a self-spawned headless one).
- **`mcp` is a hard dep of browser-use.** Yes, despite Li's anti-MCP
  preference, browser-use 0.12 lists `mcp==1.26.0` in `requires_dist`.
  This is for browser-use's *outbound* MCP support (its
  `BrowserUseMCP` server, not anything we'd run). Doesn't force
  CriomOS to use MCP — just a transitive Python dep.
- **gen 80 not yet booted.** Per `0030`, ouranos still on gen 75.
  Real-Chrome integration testing is blocked until reboot. Smoke test
  here used a self-spawned Chrome on a separate user-data-dir, which
  is enough to validate the install path but not the
  hexis-seeded-state path.

## Next step

Awaiting Li's call on the four [Surface decisions](#surface-decisions),
then implement:

1. Add `uv2nix` + `pyproject-nix` flake inputs to CriomOS-home.
2. Author `packages/browser-use/{pyproject.toml,uv.lock,default.nix}`.
3. Wire into `modules/home/profiles/max/default.nix` `atLeastLarge`
   block alongside the Chrome wrap.
4. Build `nix build .#homeConfigurations.<user>@<host>.activationPackage`
   to verify, hand-test `browser-use --help`.
5. Post-reboot: re-run a real script against the seeded Chrome.

`bd CriomOS-bu0` (suggested) — track until landed.
