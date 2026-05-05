# Hyprvoice OpenAI Implementation

Research date: 2026-05-05.

This follows [`0042-linux-stt-typing-options.md`](0042-linux-stt-typing-options.md)
and narrows the implementation target to Hyprvoice with OpenAI speech-to-text.
No paid STT or LLM API call was made while researching or validating this.

## Current Answer

Use Hyprvoice as the first OpenAI-backed dictation implementation with the
common upstream desktop trust model: a private Home Manager service wrapper
reads `gopass openai/api-key`, exports `OPENAI_API_KEY`, and execs
`hyprvoice serve`. Start with batch `gpt-4o-transcribe`, not OpenAI Realtime.

Hyprvoice `v1.0.2` already exposes the useful surface: a user daemon,
PipeWire microphone capture, OpenAI `whisper-1`, `gpt-4o-transcribe`,
`gpt-4o-mini-transcribe`, `gpt-4o-realtime-preview`, optional LLM cleanup,
keywords, and text injection through `ydotool`, `wtype`, or clipboard.
CriomOS uses Hyprvoice's upstream `wtype` backend for the first unpatched
self-insertion trial on niri. Clipboard support remains available as an
explicit secondary backend, but it is not the acceptance path for typed
dictation.

For CriomOS/niri, the implementation should be:

1. Package Hyprvoice from source as a Nix derivation in `CriomOS-home`.
2. Add a Home Manager `dictation` module that owns Hyprvoice config, the
   user service, the private gopass-backed daemon wrapper, and the niri toggle
   binding.
3. Avoid any current NixOS-level input daemon or group dependency for
   dictation; `wtype` uses Wayland's virtual-keyboard protocol.
4. Configure initial transcription as OpenAI `gpt-4o-transcribe`, LLM cleanup
   disabled, injection backends `["wtype", "clipboard"]`, and no `ydotool` in
   the dictation text path.

The important shape is that Hyprvoice is a user-session application. The
package and service belong near the home-manager profile. There is no
privileged CriomOS system surface for the current `wtype` path.

## Audit Findings

The strict audit found seven concrete issues. The first implementation accepts
Hyprvoice's common env/config trust model for the OpenAI key, so the first two
items are accepted tradeoffs rather than blockers:

1. **The OpenAI key boundary is wider than intended.** A service wrapper that
   exports `OPENAI_API_KEY` before `exec hyprvoice serve` gives the key to the
   Hyprvoice process. Hyprvoice then starts `pw-record`, `pw-cli`, `ydotool`,
   `wtype`, `wl-copy`, `notify-send`, and `whisper-cli` with Go's default child
   environment inheritance. This is wider than the earlier strict boundary
   request, but it matches the common upstream desktop model.
2. **Environment variables are the wrong secret transport for a long-running
   service under a strict model.** systemd's own documentation says service
   environment variables are exposed via manager APIs and propagate down the
   process tree. This is acceptable for the chosen upstream-style first pass,
   but not for a future least-privilege credential boundary.
3. **`ydotool type` is not enough for the target text under Colemak.** Upstream
   `ydotool` types key positions that are interpreted by niri's configured
   layout; the first live test turned "this is a test..." into Colemak-mapped
   garbage. Clipboard can remain an explicit backend, but it is not an
   acceptable answer to broken self-insertion. The active unpatched repair path
   is the upstream Hyprvoice `wtype` backend.
4. **The proposed TOML is incomplete.** Hyprvoice `v1.0.2` does not apply
   recording defaults when loading a hand-written config. Omitting `[recording]`
   leaves zero sample rate, channels, and buffer sizes; the initial validation
   only logs a warning, but recording later fails.
5. **Home Manager ownership conflicts with Hyprvoice's mutable config model.**
   `xdg.configFile."hyprvoice/config.toml".text` makes the config a Nix-owned
   symlink. That is correct only if Hyprvoice's interactive `configure` and
   `onboarding` flows are deliberately out of scope.
6. **The service startup environment is racy.** Importing `WAYLAND_DISPLAY` and
   `XDG_RUNTIME_DIR` into the user manager helps only for services started after
   the import. A service started at `default.target` can keep a stale or missing
   graphical environment.
7. **The report trusted upstream docs where the tag disagrees.** Hyprvoice
   `v1.0.2` documentation describes `hyprvoice test-models`, but the tagged CLI
   does not expose that command. Provider smoke tests therefore need a different
   local harness or a newer upstream tag.

## Deferred Strict-Boundary Research

### Secret Boundary

This section is not part of the first implementation. It records the repair path
if CriomOS later decides that Hyprvoice's common env-key model is too broad.

There is no shell-only wrapper that gives the OpenAI key strictly to Hyprvoice
and guarantees Hyprvoice's children do not inherit it. In Go, an `exec.Cmd` with
`Env = nil` inherits the parent process environment. Hyprvoice uses that default
for the external programs it starts.

The strict repair would be a small local Hyprvoice patch:

- Add a helper for child commands that removes cloud API key variables
  (`OPENAI_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `ELEVENLABS_API_KEY`,
  `DEEPGRAM_API_KEY`) before spawning non-provider executables.
- Use that helper for `pw-record`, `pw-cli`, `ydotool`, `wtype`, `wl-copy`,
  `notify-send`, `whisper-cli`, and dependency probes.
- Remove or gate logs that print full transcript text.
- Add a provider credential source that is not process-wide environment, such
  as `api_key_command` or `$CREDENTIALS_DIRECTORY/openai-api-key`.

The least invasive implementation is `api_key_command`:

```toml
[providers.openai]
api_key_command = ["gopass", "show", "-o", "openai/api-key"]
```

Hyprvoice would execute that command only when constructing the OpenAI adapter,
trim the trailing newline, keep the result in memory, and still sanitize every
non-provider child process. This keeps secret bytes out of the Nix store, out of
the user service environment, and out of unrelated subprocess environments.

This preserves the requested shape: the secret source is still
`gopass openai/api-key`. Nix should contain only the command path and arguments,
never the secret value. The Home Manager module should render `gopass` as an
absolute Nix package path in the generated TOML, or otherwise ensure the daemon
wrapper PATH contains `gopass`.

The source patch shape is:

- extend `ProviderConfig` with `APIKeyCommand []string`;
- make provider key resolution check `providers.<name>.api_key`, then
  `providers.<name>.api_key_command`, then the legacy environment variable;
- run `api_key_command` directly with `exec.CommandContext`, not through a
  shell;
- apply a short timeout, trim one trailing newline, reject empty output, and
  never log command output;
- make `Validate`, transcription config conversion, and LLM config conversion
  use the same resolver.

The child-command sanitization patch should centralize command construction:

```go
func commandWithoutCloudKeys(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = withoutCloudKeys(os.Environ())
	return cmd
}
```

Then replace the non-provider process spawns with that helper. This is the
actual boundary repair; wrapping only `hyprvoice serve` cannot provide it.

If we avoid patching credential loading in the first pass, the temporary repair
is a private runtime config wrapper:

- Home Manager writes a non-secret complete config template.
- The service wrapper copies that template into a `0700` runtime config
  directory below `XDG_RUNTIME_DIR`.
- The wrapper appends `[providers.openai].api_key` from
  `gopass show -o openai/api-key`.
- The wrapper sets `XDG_CONFIG_HOME` to that runtime directory and does not
  export `OPENAI_API_KEY`.

That temporary path avoids child environment leakage but still leaves the key in
a same-user-readable runtime file. The stricter durable path is the Hyprvoice
patch.

### Text Insertion

The first live test proved the layout problem: with niri configured for
Colemak, `ydotool type` sent QWERTY positions that niri interpreted through the
Colemak layout. The result was unreadable. CriomOS must not paper over this by
treating clipboard copy or paste as the fix for self-insertion.

The researched correction is to use Hyprvoice as it is actually shaped before
carrying a local patch. Hyprvoice `v1.0.2` constructs an ordered backend chain
from `["ydotool", "wtype", "clipboard"]` names; `wtype` and `clipboard` are
upstream backends, while `dotool` is not. The `wtype` backend invokes
`wtype -- <text>`, and `wtype` uploads a generated XKB keymap for the text
before sending virtual-keyboard events. That is the upstream typing path that
can avoid the `ydotool` physical-key/layout failure.

The acceptable first repair is therefore a keyboard-injection path that types
the intended text:

1. Use Hyprvoice's upstream `wtype` backend first. `wtype` sends text through
   the Wayland virtual-keyboard protocol and uploads a generated keymap for the
   text being typed.
2. Keep `wtype` in the Hyprvoice package wrapper so the user service sees it.
3. Keep clipboard support available for workflows that explicitly want the
   transcript copied.
4. Do not make the current dictation path depend on `ydotoold`, an input group,
   or a local `dotool` patch.

The live niri session accepts `wtype ""`, which verifies that the compositor
exposes the virtual-keyboard path without injecting text.

This is still a trial, not a proven durable answer. Current upstream niri issues
show `wtype` can make the focused app stop receiving real keyboard input and
can produce gibberish when focus changes. If those bugs reproduce in the live
Colemak dictation test, unpatched Hyprvoice has no remaining correct
self-insertion backend for this environment. The next honest choices would be:
propose/add upstream `dotool` support, or switch to a dictation tool that
already has a layout-aware fallback chain.

### Complete Config

The Home Manager module must generate a complete Hyprvoice config. At minimum
it needs the upstream recording defaults plus all timeout fields that Hyprvoice
validates:

```toml
[recording]
sample_rate = 16000
channels = 1
format = "s16"
buffer_size = 8192
device = ""
channel_buffer_size = 30
timeout = "5m"

[transcription]
provider = "openai"
model = "gpt-4o-transcribe"
language = ""
streaming = false
threads = 0

[injection]
# wtype uses Wayland virtual-keyboard text injection; clipboard remains
# available as the explicit non-typing backend.
backends = ["wtype", "clipboard"]
ydotool_timeout = "5s"
wtype_timeout = "5s"
clipboard_timeout = "3s"

[notifications]
enabled = true
type = "desktop"

[llm]
enabled = false
```

The live Colemak test failed with `ydotool`, so the first unpatched
implementation uses `wtype` for typing. Clipboard insertion remains available as
a separate backend, but it is not the self-insertion fix.

### Config Ownership

There are two valid ownership modes:

- **Nix-owned dictation config.** Home Manager owns `config.toml`; users do not
  run `hyprvoice configure` or `hyprvoice onboarding` for the production daemon.
- **Managed mutable config.** A hexis-style managed file owns the durable
  defaults while allowing runtime edits.

The first implementation should use Nix-owned config because it is simpler and
matches CriomOS reproducibility. If interactive tuning becomes important, move
to managed mutable config deliberately rather than letting Hyprvoice mutate an
HM symlink.

### Service Startup

Do not install the service as a generic `default.target` user service. Start it
from the niri session after the environment import has run.

The niri module already has a session environment sync helper. Replace the
separate first startup command with a small session bootstrap script that:

1. imports `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`,
   `XDG_SESSION_TYPE`, and `XDG_RUNTIME_DIR` into systemd and D-Bus activation
   environments;
2. starts or restarts `hyprvoice.service`.

That makes Hyprvoice receive the same graphical/session environment that niri is
actually using. If CriomOS later uses `niri.service` directly, install
`hyprvoice.service` under the niri service wants graph instead.

### System Surface

The current `wtype` dictation path needs no system-level input daemon and no
extra user group. `wtype` is a user-session Wayland client.

If a future backend deliberately uses `/dev/uinput`, that system surface
belongs in CriomOS and must be justified by the configured backend. It should
not be present merely because Hyprvoice also has an optional `ydotool` backend.

### OpenAI Surface

The batch model choice still holds. OpenAI's current docs list
`gpt-4o-transcribe` and `gpt-4o-mini-transcribe` as transcription models, with
estimated costs of `$0.006 / minute` and `$0.003 / minute`.

Realtime remains a second phase, but the repair is clearer: Hyprvoice
`v1.0.2` should not be used as-is for OpenAI Realtime. Official docs now show
transcription sessions opened with `intent=transcription` and configured through
`transcription_session.update` / transcription session fields. Hyprvoice
`v1.0.2` opens `/v1/realtime?model=gpt-4o-realtime-preview` and sends the older
conversation-session shape. A Realtime phase should patch the adapter to the
current transcription session API before any paid test.

## Upstream Shape

Hyprvoice `v1.0.2` is a Go application with module path
`github.com/leonardotrapani/hyprvoice` and `go 1.24.5` in `go.mod`. Its command
entry point is `./cmd/hyprvoice`. Upstream release CI builds a Linux binary with
`go build ./cmd/hyprvoice`, and the release page publishes a single
`hyprvoice-linux-x86_64` binary, but CriomOS should build from source.

The runtime calls external programs by name:

- `pw-record` and `pw-cli` from PipeWire for audio capture and checks.
- `ydotool` and `ydotoold` only if the configured backend asks for
  compositor-independent key-position typing.
- `wtype` for the current Wayland typing path.
- `wl-copy` for the explicit clipboard backend.
- `notify-send` for desktop notifications.
- `whisper-cli` only when using the local `whisper-cpp` provider.

The Nix package should wrap `hyprvoice` with a `PATH` containing at least
`pipewire`, `libnotify`, `wtype`, and `wl-clipboard`. Add `ydotool`,
`dotool`, or `whisper-cpp` only when the configured backend/provider actually
uses it.
Relying on the ambient user PATH would make the service brittle.

Local validation:

- `go test ./...` passes with `CI=true` and all paid API key environment
  variables unset.
- Without `CI=true`, the injection test suite expects live `wtype` support and
  fails in this session because `wtype` is absent.
- `CGO_ENABLED=0 go build ./cmd/hyprvoice` succeeds with `go_1_25`, despite
  upstream release CI setting `CGO_ENABLED=1`.

## Package Shape

The package should live in `CriomOS-home/packages/hyprvoice/default.nix` or the
equivalent blueprint-discovered package path:

```nix
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  makeWrapper,
  pipewire,
  libnotify,
  wtype,
  wl-clipboard,
}:

buildGoModule {
  pname = "hyprvoice";
  version = "1.0.2";

  src = fetchFromGitHub {
    owner = "LeonardoTrapani";
    repo = "hyprvoice";
    tag = "v${version}";
    hash = "...";
  };

  vendorHash = "...";
  subPackages = [ "cmd/hyprvoice" ];

  env.CGO_ENABLED = "0";
  nativeBuildInputs = [ makeWrapper ];

  preCheck = ''
    export CI=true
  '';

  postInstall = ''
    wrapProgram $out/bin/hyprvoice \
      --prefix PATH : ${
        lib.makeBinPath [
          pipewire
          libnotify
          wtype
          wl-clipboard
        ]
      }
  '';

  meta = {
    description = "Voice-powered typing for Wayland desktops";
    homepage = "https://github.com/LeonardoTrapani/hyprvoice";
    license = lib.licenses.mit;
    mainProgram = "hyprvoice";
  };
}
```

`ydotool`, `dotool`, and `whisper-cpp` can be omitted from the wrapper until the
module config uses them. Keeping tools in the wrapper before the module config
uses them makes dependency failures less legible, not more.

## System Surface

`wtype` uses the Wayland virtual-keyboard protocol and does not need a NixOS
uinput group. The current Hyprvoice dictation path therefore has no CriomOS
system-layer change.

If a later backend deliberately uses `ydotool` or `dotool`, the corresponding
`/dev/uinput` service/group belongs in CriomOS, gated by edge/graphical profile
and wired through horizon-built users without naming a local user, node, or
cluster.

## Home Surface

Add a `CriomOS-home` module such as `modules/home/profiles/min/dictation.nix`
and import it from `modules/home/default.nix` near the existing niri module.
The module should own:

- `home.packages = [ hyprvoice ];`
- `xdg.configFile."hyprvoice/config.toml".text`
- `systemd.user.services.hyprvoice`
- the niri keybinding
- a private service wrapper that reads `gopass openai/api-key`, exports
  `OPENAI_API_KEY`, and execs `hyprvoice serve`

The config should be complete and Nix-owned. The initial version should be:

```toml
[recording]
sample_rate = 16000
channels = 1
format = "s16"
buffer_size = 8192
device = ""
channel_buffer_size = 30
timeout = "5m"

[transcription]
provider = "openai"
model = "gpt-4o-transcribe"
language = ""
streaming = false
threads = 0

[injection]
# wtype uses Wayland virtual-keyboard text injection; clipboard remains
# available as the explicit non-typing backend.
backends = ["wtype", "clipboard"]
ydotool_timeout = "5s"
wtype_timeout = "5s"
clipboard_timeout = "3s"

[notifications]
enabled = true
type = "desktop"

[llm]
enabled = false
```

Because Home Manager owns the durable Hyprvoice config, that config stays
non-secret. The key source is `gopass openai/api-key`; Nix contains only the
wrapper script and command path, never the key value.

The package binary itself must remain unwrapped for secrets. Client commands
such as `hyprvoice toggle`, `hyprvoice status`, `hyprvoice cancel`, and the niri
binding only talk to the daemon over Hyprvoice IPC; they do not need the OpenAI
key and should not receive it. Commands that intentionally call provider APIs
need an explicit command path and explicit user permission before any paid test.

The wrapper is private to this module:

```nix
hyprvoiceServe = pkgs.writeShellScript "hyprvoice-serve" ''
  set -eu

  OPENAI_API_KEY="$(${pkgs.gopass}/bin/gopass show -o openai/api-key)"
  export OPENAI_API_KEY

  exec ${hyprvoice}/bin/hyprvoice serve
'';
```

Then the service runs only that private wrapper:

```nix
systemd.user.services.hyprvoice.Service.ExecStart = "${hyprvoiceServe}";
```

The systemd user service needs the graphical session environment. CriomOS-home
already has a niri startup helper that imports display variables into the user
manager; extend that helper to include `XDG_RUNTIME_DIR`. Start or restart
`hyprvoice.service` from that same niri session bootstrap after the import,
rather than installing it under generic `default.target`.

## Niri Binding

Hyprvoice's upstream Hyprland docs show both toggle and hold-to-record. Current
niri keybinding docs show normal press bindings, repeat control, and spawn
actions; they do not show a key-release binding equivalent to Hyprland `bindr`.
The first niri integration should therefore use a two-press toggle:

```nix
"Mod+V" = {
  action = a.spawn "${hyprvoice}/bin/hyprvoice" "toggle";
  repeat = false;
  hotkey-overlay-title = "Voice Typing";
};
```

Hold-to-record can be a later enhancement if niri grows release bindings or if
a separate input helper is justified. It is not needed for the first useful
trial.

## OpenAI Model Choice

Use `gpt-4o-transcribe` first. It is the quality-first OpenAI STT model and
the current fit for "best typing quality." Use `gpt-4o-mini-transcribe` only
if cost or latency matters more than accuracy.

OpenAI's current pricing page lists estimated transcription costs of:

- `gpt-4o-transcribe`: `$0.006 / minute`.
- `gpt-4o-mini-transcribe`: `$0.003 / minute`.

OpenAI's model page also lists token pricing for `gpt-4o-transcribe`; the
pricing page is the better user-facing estimate for dictation because it
publishes the per-minute estimate directly.

OpenAI Realtime should stay second phase. Official docs now describe
transcription-only realtime sessions with `type = "transcription"` and an
`audio.input.transcription.model` such as `gpt-4o-transcribe` or
`gpt-4o-mini-transcribe`. Hyprvoice `v1.0.2` uses a Realtime adapter that opens
`/v1/realtime?model=gpt-4o-realtime-preview` and hardcodes
`input_audio_transcription.model = "gpt-4o-transcribe"`. That may still work
through backwards compatibility, but it is a moving API surface and should not
be the first trial.

## Injection Risks

`wtype` is the least-patchy upstream typing backend left after the Colemak
`ydotool` failure. It is also risky on niri: current upstream niri issues still
describe wrong characters and focused-app keyboard breakage after `wtype`.

The first backend is `wtype`. It depends on:

- `wtype` being in the Hyprvoice wrapper PATH;
- `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` being visible to the Hyprvoice user
  service;
- niri exposing the virtual-keyboard protocol.

The clipboard backend in Hyprvoice `v1.0.2` only calls `wl-copy`. It copies the
transcript; it does not type text or trigger paste. CriomOS can keep that
backend available, but it cannot be the acceptance path for self-insertion.
With Hyprvoice's ordered backend chain, clipboard only runs after an earlier
backend returns an error; it did not catch the Colemak failure because
`ydotool type` returned success after sending the wrong physical key positions.
Hyprvoice does not expose per-toggle backend selection in this release, so
"both" means an ordered backend chain. If CriomOS later wants a separate
clipboard dictation shortcut alongside a typing shortcut, use a second
configuration/daemon profile or patch Hyprvoice with per-request backend
selection.

`ydotool type` failed the live Colemak test. The current path for
self-insertion is Hyprvoice's upstream `wtype` backend. If the niri `wtype`
bugs reproduce, do not silently demote self-insertion to clipboard copy; choose
between adding/proposing layout-aware upstream typing support or switching
tools.

## Implementation Order

1. Add the Hyprvoice source package to `CriomOS-home` and run package checks
   with `CI=true` and all cloud API key variables unset.
2. Add the `dictation` Home Manager module with the complete OpenAI batch
   config and private gopass-backed daemon wrapper.
3. Add the niri `Mod+V` toggle binding and start/restart the daemon from the
   niri session bootstrap after importing session environment variables.
4. Build and deploy through the normal lojix/CriomOS path.
5. Test local behavior without paid APIs: service startup, toggle IPC,
   microphone capture failure reporting, and `wtype` ASCII smoke behavior.
6. Treat dictation as accepted under Colemak only after the upstream `wtype`
   backend types the intended text in the live niri session.
7. Only after explicit permission, run real OpenAI transcription tests against
   `gpt-4o-transcribe`.

## Sources Checked

- Hyprvoice repository and README:
  <https://github.com/LeonardoTrapani/hyprvoice>
- Hyprvoice `v1.0.2` release:
  <https://github.com/LeonardoTrapani/hyprvoice/releases/tag/v1.0.2>
- Hyprvoice config docs:
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/docs/config.md>
- Hyprvoice provider docs:
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/docs/providers.md>
- Hyprvoice user service:
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/packaging/hyprvoice.service>
- Hyprvoice source files inspected for child processes, config loading, and
  insertion behavior:
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/recording/recording.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/injection.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/wtype.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/ydotool.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/clipboard.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/config/load.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/config/defaults.go>
- `wtype` source and docs:
  <https://github.com/atx/wtype/blob/master/main.c>,
  <https://github.com/atx/wtype/blob/master/README.md>
- niri `wtype` issue checks:
  <https://github.com/niri-wm/niri/issues/2280>,
  <https://github.com/niri-wm/niri/issues/2314>,
  <https://github.com/niri-wm/niri/issues/1546>,
  <https://github.com/niri-wm/niri/issues/3394>
- Voxtype docs for the existing `wtype`/`dotool`/`ydotool`/clipboard fallback
  shape:
  <https://github.com/peteonrails/voxtype/blob/main/README.md>,
  <https://github.com/peteonrails/voxtype/blob/main/docs/USER_MANUAL.md>
- Go `os/exec.Cmd` environment behavior:
  <https://pkg.go.dev/os/exec#Cmd>
- systemd service environment and credentials documentation:
  <https://www.freedesktop.org/software/systemd/man/systemd.exec.html>
- OpenAI speech-to-text docs:
  <https://developers.openai.com/api/docs/guides/speech-to-text>
- OpenAI realtime transcription docs:
  <https://developers.openai.com/api/docs/guides/realtime-transcription>
- OpenAI realtime costs docs:
  <https://developers.openai.com/api/docs/guides/realtime-costs>
- OpenAI pricing:
  <https://platform.openai.com/docs/pricing>
- OpenAI `gpt-4o-transcribe` model page:
  <https://developers.openai.com/api/docs/models/gpt-4o-transcribe>
- `ydotool` non-QWERTY issue:
  <https://github.com/ReimuNotMoe/ydotool/issues/43>
- `ydotool` accented character issue:
  <https://github.com/ReimuNotMoe/ydotool/issues/22>
- `dotool` upstream homepage:
  <https://git.sr.ht/~geb/dotool>
- niri keybinding docs:
  <https://niri-wm.github.io/niri/Configuration%3A-Key-Bindings.html>
