# Hyprvoice OpenAI Implementation

Research date: 2026-05-05.

This follows [`0042-linux-stt-typing-options.md`](0042-linux-stt-typing-options.md)
and narrows the implementation target to Hyprvoice with OpenAI speech-to-text.
No paid STT or LLM API call was made while researching or validating this.

## Current Answer

Use Hyprvoice as the first OpenAI-backed dictation implementation only after a
small local repair layer. Start with batch `gpt-4o-transcribe`, not OpenAI
Realtime.

Hyprvoice `v1.0.2` already exposes the useful surface: a user daemon,
PipeWire microphone capture, OpenAI `whisper-1`, `gpt-4o-transcribe`,
`gpt-4o-mini-transcribe`, `gpt-4o-realtime-preview`, optional LLM cleanup,
keywords, and text injection through `ydotool`, `wtype`, or clipboard.

For CriomOS/niri, the repaired implementation should be:

1. Package Hyprvoice from source as a Nix derivation in `CriomOS-home`.
2. Carry a local Hyprvoice patch for secret handling, transcript logging, and
   Unicode-safe paste insertion.
3. Enable the NixOS `ydotoold` service from `CriomOS` only on edge/graphical
   hosts.
4. Add a Home Manager `dictation` module that owns Hyprvoice config, the
   user service, OpenAI credential source, and the niri toggle binding.
5. Configure initial transcription as OpenAI `gpt-4o-transcribe`, LLM cleanup
   disabled, paste-first insertion, and no `wtype` until niri-specific testing
   says it is stable.

The important shape is that Hyprvoice is a user-session application. The
package and service belong near the home-manager profile; only privileged
uinput support belongs in CriomOS.

## Audit Findings

The original proposal is not ready to implement unchanged. It has seven
concrete flaws:

1. **The OpenAI key boundary is wider than intended.** A service wrapper that
   exports `OPENAI_API_KEY` before `exec hyprvoice serve` gives the key to the
   Hyprvoice process. Hyprvoice then starts `pw-record`, `pw-cli`, `ydotool`,
   `wtype`, `wl-copy`, `notify-send`, and `whisper-cli` with Go's default child
   environment inheritance. That violates the intended boundary that only the
   executable needing the key receives it.
2. **Environment variables are the wrong secret transport for a long-running
   service.** systemd's own documentation says service environment variables are
   exposed via manager APIs and propagate down the process tree. The wrapper is
   acceptable only as a temporary bridge if the application sanitizes child
   environments.
3. **`ydotool type` is not enough for the target text.** Upstream `ydotool`
   has open issues around non-QWERTY layouts and accented characters. That makes
   it a poor primary path for Colemak plus Sanskrit/IAST or other Unicode text.
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

## Repair Research

### Secret Boundary

There is no shell-only wrapper that gives the OpenAI key strictly to Hyprvoice
and guarantees Hyprvoice's children do not inherit it. In Go, an `exec.Cmd` with
`Env = nil` inherits the parent process environment. Hyprvoice uses that default
for the external programs it starts.

The right repair is a small local Hyprvoice patch:

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

The Home Manager module should render `gopass` as an absolute Nix package path
in the generated TOML, or otherwise ensure the daemon wrapper PATH contains
`gopass`; the secret itself still comes from `gopass openai/api-key`.

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

The first useful insertion path should be paste-first, not `ydotool type`.
`ydotool` remains useful for small control chords, but it is not the right tool
to type arbitrary transcript text under Colemak and Unicode vocabulary.

Patch Hyprvoice with a backend such as `clipboard-paste`:

1. Save the current clipboard when possible with `wl-paste`.
2. Copy transcript text with `wl-copy`.
3. Trigger paste with a configurable command, initially `ydotool key ctrl+v`.
4. Optionally restore the previous clipboard after a short delay.

This sends text through the clipboard as Unicode text and uses the synthetic
keyboard only for the paste shortcut. If that is not stable enough, add a
`dotool` backend. `dotool` is in nixpkgs, has a long-running daemon/client
shape, and supports XKB layout selection through `DOTOOL_XKB_LAYOUT` and
`DOTOOL_XKB_VARIANT`; it also requires careful `/dev/uinput` access design.

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
backends = ["clipboard-paste", "clipboard"]
ydotool_timeout = "5s"
wtype_timeout = "5s"
clipboard_timeout = "3s"

[notifications]
enabled = true
type = "desktop"

[llm]
enabled = false
```

Until `clipboard-paste` exists, use `["ydotool", "clipboard"]` only for ASCII
smoke testing and treat Unicode/IAST insertion as expected-failing.

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
- `wl-copy` for clipboard fallback.
- `notify-send` for desktop notifications.
- `whisper-cli` only when using the local `whisper-cpp` provider.

The Nix package should apply the local repair patches at build time and wrap
`hyprvoice` with a `PATH` containing at least `pipewire`, `wl-clipboard`,
`libnotify`, and `ydotool`. Add `dotool`, `wtype`, and `whisper-cpp` only when
the configured backend/provider actually uses them. Relying on the ambient user
PATH would make the service brittle, and hiding security repairs in shell
wrappers would leave the daemon's child-process behavior unchanged.

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
  wl-clipboard,
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
          wl-clipboard
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

`dotool`, `wtype`, and `whisper-cpp` can be omitted from the wrapper at first if
the first trial is strictly OpenAI plus clipboard-paste insertion. Keeping tools
in the wrapper before the module config uses them makes dependency failures
less legible, not more.

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
- the provider key source, without exporting the key into the daemon's process
  environment

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
backends = ["clipboard-paste", "clipboard"]
ydotool_timeout = "5s"
wtype_timeout = "5s"
clipboard_timeout = "3s"

[notifications]
enabled = true
type = "desktop"

[llm]
enabled = false
```

Do not put the OpenAI key in the Nix-owned `config.toml`. The durable repair is
to patch Hyprvoice so the OpenAI provider can read:

```toml
[providers.openai]
api_key_command = ["gopass", "show", "-o", "openai/api-key"]
```

That command belongs inside the OpenAI adapter construction path. It should not
be a package wrapper, a general executable on PATH, or a process-wide
environment import.

If the first implementation does not include `api_key_command`, use the runtime
config bridge described in the repair section: generate a private config below
`XDG_RUNTIME_DIR`, append the OpenAI key there, set `XDG_CONFIG_HOME` for the
daemon, and keep `OPENAI_API_KEY` unset. This bridge is less good than the patch
because the key becomes a same-user-readable runtime file, but it still avoids
leaking the key to `pw-record`, `ydotool`, `wl-copy`, and notification
subprocesses.

The package binary itself must remain unwrapped. Client commands such as
`hyprvoice toggle`, `hyprvoice status`, `hyprvoice cancel`, and the niri binding
only talk to the daemon over Hyprvoice IPC; they do not need the OpenAI key and
should not receive it. Commands that intentionally call provider APIs need an
explicit command path and explicit user permission before any paid test.

With the durable `api_key_command` patch, the user service can run Hyprvoice
directly:

```nix
systemd.user.services.hyprvoice = {
  Unit = {
    Description = "Hyprvoice dictation daemon";
    PartOf = [ "graphical-session.target" ];
  };

  Service = {
    ExecStart = "${hyprvoice}/bin/hyprvoice serve";
    Restart = "on-failure";
    Environment = [
      "YDOTOOL_SOCKET=/run/ydotoold/socket"
    ];
  };
};
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

The repaired first backend is clipboard-paste. It depends on:

- `wl-copy` and `wl-paste` from `wl-clipboard`;
- `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` being visible to the user service;
- a reliable paste trigger, initially `ydotool key ctrl+v`;
- the NixOS `ydotoold` service, group membership, and `YDOTOOL_SOCKET` only for
  that small paste chord.

The clipboard backend in Hyprvoice `v1.0.2` only calls `wl-copy`. It copies the
transcript; it does not type text or trigger paste. Treat it as a recovery path,
not as the main typing backend.

`ydotool type` remains useful only as an ASCII smoke-test backend. It should not
be the acceptance path for mixed layout or Unicode dictation.

## Implementation Order

1. Patch Hyprvoice for sanitized child-command environments, reduced transcript
   logging, `api_key_command`, and `clipboard-paste`.
2. Add the patched Hyprvoice source package to `CriomOS-home` and run package
   checks with `CI=true` and all cloud API key variables unset.
3. Add the `dictation` Home Manager module with the complete OpenAI batch config
   and the user service that runs Hyprvoice directly.
4. Gate `programs.ydotool` in CriomOS to edge/graphical hosts and extend
   horizon-built users with the configured ydotool group.
5. Add the niri `Mod+V` toggle binding and start/restart the daemon from the
   niri session bootstrap after importing session environment variables.
6. Build and deploy through the normal lojix/CriomOS path, then log out and
   back in so the group membership and user manager environment are fresh.
7. Test local behavior without paid APIs: service startup, toggle IPC,
   microphone capture failure reporting, clipboard-paste insertion, and
   `ydotool type` ASCII smoke behavior.
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
