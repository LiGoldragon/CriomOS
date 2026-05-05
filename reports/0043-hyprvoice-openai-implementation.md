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
CriomOS intentionally does not use clipboard insertion for dictation.

For CriomOS/niri, the implementation should be:

1. Package Hyprvoice from source as a Nix derivation in `CriomOS-home`.
2. Add a Home Manager `dictation` module that owns Hyprvoice config, the
   user service, the private gopass-backed daemon wrapper, and the niri toggle
   binding.
3. Enable the NixOS `ydotoold` service from `CriomOS` only on edge/graphical
   hosts.
4. Configure initial transcription as OpenAI `gpt-4o-transcribe`, LLM cleanup
   disabled, injection backends `["ydotool"]`, and no `wtype` until
   niri-specific testing says it is stable.

The important shape is that Hyprvoice is a user-session application. The
package and service belong near the home-manager profile; only privileged
uinput support belongs in CriomOS.

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
   garbage. Clipboard insertion is not an acceptable fallback. The forward path
   is a layout-aware keyboard injection backend.
4. **The proposed TOML is incomplete.** Hyprvoice `v1.0.2` does not apply
   recording defaults when loading a hand-written config. Omitting `[recording]`
   leaves zero sample rate, channels, and buffer sizes; the initial validation
   only logs a warning, but recording later fails.
5. **Home Manager ownership conflicts with Hyprvoice's mutable config model.**
   `xdg.configFile."hyprvoice/config.toml".text` makes the config a Nix-owned
   symlink. That is correct only if Hyprvoice's interactive `configure` and
   `onboarding` flows are deliberately out of scope.
6. **The service startup environment is racy.** Importing `WAYLAND_DISPLAY`,
   `XDG_RUNTIME_DIR`, and `YDOTOOL_SOCKET` into the user manager helps only for
   services started after the import. A service started at `default.target` can
   keep a stale or missing graphical environment.
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
copying transcripts into the clipboard or triggering paste.

The acceptable repair is a keyboard-injection path that understands the active
layout:

1. Prefer a layout-aware backend such as `dotool`, configured with
   `DOTOOL_XKB_LAYOUT=us` and `DOTOOL_XKB_VARIANT=colemak`, if it behaves
   correctly under niri.
2. If no existing tool satisfies this, patch Hyprvoice with a dedicated
   layout-aware backend rather than a clipboard-based backend.
3. Keep `ydotool` available for explicit key chords where key positions are the
   desired abstraction.

`dotool` is in nixpkgs, has a long-running daemon/client shape, and supports
XKB layout selection through `DOTOOL_XKB_LAYOUT` and `DOTOOL_XKB_VARIANT`; it
also requires careful `/dev/uinput` access design.

`wtype` stays excluded from the first trial because the niri-specific issues in
the previous report are about focus/input correctness, not just packaging.

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
backends = ["ydotool"]
ydotool_timeout = "5s"
wtype_timeout = "5s"
clipboard_timeout = "3s"

[notifications]
enabled = true
type = "desktop"

[llm]
enabled = false
```

The live Colemak test failed, so the next implementation step is replacing the
text backend with a layout-aware keyboard injection path. Clipboard insertion is
excluded.

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
   `XDG_SESSION_TYPE`, `XDG_RUNTIME_DIR`, and `YDOTOOL_SOCKET` into systemd and
   D-Bus activation environments;
2. starts or restarts `hyprvoice.service`.

That makes Hyprvoice receive the same graphical/session environment that niri is
actually using. If CriomOS later uses `niri.service` directly, install
`hyprvoice.service` under the niri service wants graph instead.

### System Surface

Enable uinput tooling only for edge hosts:

```nix
mkIf behavesAs.edge {
  programs.ydotool.enable = size.atLeastMin;
}
```

Keep the user group extension in `modules/nixos/users.nix` using
`config.programs.ydotool.group`, as originally proposed. If `dotool` becomes
part of the insertion path, add an explicit access decision for `/dev/uinput`;
do not silently add every user to the broad `input` group without a short
report update.

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
- `ydotool` and `ydotoold` for compositor-independent typing.
- `wtype` for Wayland typing.
- `wl-copy` only if a future non-dictation command explicitly needs it.
- `notify-send` for desktop notifications.
- `whisper-cli` only when using the local `whisper-cpp` provider.

The Nix package should wrap `hyprvoice` with a `PATH` containing at least
`pipewire`, `libnotify`, and `ydotool`. Add `wtype`, `whisper-cpp`, `dotool`,
or `wl-clipboard` only when the configured backend/provider actually uses them.
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
  ydotool,
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
          ydotool
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

`wtype`, `whisper-cpp`, `dotool`, and `wl-clipboard` can be omitted from the
wrapper until the module config uses them. Keeping tools in the wrapper before
the module config uses them makes dependency failures less legible, not more.

## System Surface

`ydotool` needs uinput access. NixOS already has `programs.ydotool.enable`,
which creates a system `ydotoold` service, a group, the `YDOTOOL_SOCKET`
environment variable, and the `ydotool` package.

CriomOS should enable it at the system layer only for edge/graphical hosts:

```nix
mkIf behavesAs.edge {
  programs.ydotool.enable = size.atLeastMin;
}
```

`modules/nixos/users.nix` should then add the configured group through the
existing horizon-driven user construction:

```nix
extraGroups =
  user.extraGroups
  ++ optional config.programs.ydotool.enable config.programs.ydotool.group
  ++ ...;
```

This preserves the repo's network-neutral rule: no local user name, node name,
or cluster name is introduced.

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
backends = ["ydotool"]
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
  export YDOTOOL_SOCKET="''${YDOTOOL_SOCKET:-/run/ydotoold/socket}"

  exec ${hyprvoice}/bin/hyprvoice serve
'';
```

Then the service runs only that private wrapper:

```nix
systemd.user.services.hyprvoice.Service.ExecStart = "${hyprvoiceServe}";
```

The systemd user service needs the graphical session environment. CriomOS-home
already has a niri startup helper that imports display variables into the user
manager; extend that helper to include `XDG_RUNTIME_DIR` and `YDOTOOL_SOCKET`.
Start or restart `hyprvoice.service` from that same niri session bootstrap after
the import, rather than installing it under generic `default.target`.

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

`wtype` is the riskier backend on niri. The prior STT report already found open
niri issues around `wtype`, and Hyprvoice does not need `wtype` for the first
trial.

The first backend is `ydotool`. It depends on:

- the NixOS `ydotoold` service running;
- the user being in the configured `ydotool` group after a new login;
- `YDOTOOL_SOCKET` being visible to the Hyprvoice user service;
- the virtual keyboard layout producing the intended text under the configured
  niri/Colemak layout.

The clipboard backend in Hyprvoice `v1.0.2` only calls `wl-copy`. It copies the
transcript; it does not type text or trigger paste. CriomOS excludes it for
dictation because it mutates clipboard state instead of solving keyboard
injection.

`ydotool type` failed the live Colemak test. The next path is layout-aware
keyboard injection, not clipboard insertion.

## Implementation Order

1. Add the Hyprvoice source package to `CriomOS-home` and run package checks
   with `CI=true` and all cloud API key variables unset.
2. Add the `dictation` Home Manager module with the complete OpenAI batch
   config and private gopass-backed daemon wrapper.
3. Gate `programs.ydotool` in CriomOS to edge/graphical hosts and extend
   horizon-built users with the configured ydotool group.
4. Add the niri `Mod+V` toggle binding and start/restart the daemon from the
   niri session bootstrap after importing session environment variables.
5. Build and deploy through the normal lojix/CriomOS path, then log out and
   back in so the group membership and user manager environment are fresh.
6. Test local behavior without paid APIs: service startup, toggle IPC,
   microphone capture failure reporting, and `ydotool type` ASCII smoke
   behavior.
7. Replace `ydotool type` with a layout-aware injection backend before treating
   dictation as accepted under Colemak.
8. Only after explicit permission, run real OpenAI transcription tests against
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
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/ydotool.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/clipboard.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/config/load.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/config/defaults.go>
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
- NixOS `ydotool` module source:
  <https://raw.githubusercontent.com/NixOS/nixpkgs/master/nixos/modules/programs/ydotool.nix>
- `ydotool` non-QWERTY issue:
  <https://github.com/ReimuNotMoe/ydotool/issues/43>
- `ydotool` accented character issue:
  <https://github.com/ReimuNotMoe/ydotool/issues/22>
- `dotool` upstream homepage:
  <https://git.sr.ht/~geb/dotool>
- niri keybinding docs:
  <https://niri-wm.github.io/niri/Configuration%3A-Key-Bindings.html>
