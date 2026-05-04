# Hyprvoice OpenAI Implementation

Research date: 2026-05-05.

This follows [`0042-linux-stt-typing-options.md`](0042-linux-stt-typing-options.md)
and narrows the implementation target to Hyprvoice with OpenAI speech-to-text.
No paid STT or LLM API call was made while researching or validating this.

## Current Answer

Use Hyprvoice as the first OpenAI-backed dictation implementation, but start
with batch `gpt-4o-transcribe`, not OpenAI Realtime.

Hyprvoice `v1.0.2` already exposes the useful surface: a user daemon,
PipeWire microphone capture, OpenAI `whisper-1`, `gpt-4o-transcribe`,
`gpt-4o-mini-transcribe`, `gpt-4o-realtime-preview`, optional LLM cleanup,
keywords, and text injection through `ydotool`, `wtype`, or clipboard.

For CriomOS/niri, the implementation should be:

1. Package Hyprvoice from source as a Nix derivation in `CriomOS-home`.
2. Enable the NixOS `ydotoold` service from `CriomOS`.
3. Add a Home Manager `dictation` module that owns Hyprvoice config, the
   user service, OpenAI key injection, and the niri toggle binding.
4. Configure initial transcription as OpenAI `gpt-4o-transcribe`, LLM cleanup
   disabled, injection backends `["ydotool", "clipboard"]`, and no `wtype`
   until niri-specific testing says it is stable.

The important shape is that Hyprvoice is a user-session application. The
package and service belong near the home-manager profile; only privileged
uinput support belongs in CriomOS.

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

The Nix package should wrap `hyprvoice` with a `PATH` containing at least
`pipewire`, `wl-clipboard`, `libnotify`, `ydotool`, and optionally `wtype` and
`whisper-cpp`. Relying on the ambient user PATH would make the service brittle.

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
  wtype,
  whisper-cpp,
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
          wtype
          whisper-cpp
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

`wtype` and `whisper-cpp` can be omitted from the wrapper at first if the first
trial is strictly OpenAI plus `ydotool`. Keeping them in the wrapper makes the
interactive `hyprvoice configure` menu less surprising.

## System Surface

`ydotool` needs uinput access. NixOS already has `programs.ydotool.enable`,
which creates a system `ydotoold` service, a group, the `YDOTOOL_SOCKET`
environment variable, and the `ydotool` package.

CriomOS should enable it at the system layer:

```nix
programs.ydotool.enable = true;
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
- an OpenAI API key wrapper used only by the daemon process

The initial config should be conservative:

```toml
[transcription]
provider = "openai"
model = "gpt-4o-transcribe"
language = ""
streaming = false
threads = 0

[injection]
backends = ["ydotool", "clipboard"]
ydotool_timeout = "5s"
clipboard_timeout = "3s"

[notifications]
enabled = true
type = "desktop"

[llm]
enabled = false
```

Do not put the OpenAI key in `config.toml`. Hyprvoice resolves
`OPENAI_API_KEY`, so use a service-only wrapper that reads the key from
`gopass` at runtime and then `exec`s `hyprvoice serve`. This matches the
existing `CriomOS-home` gopass pattern and keeps secret bytes out of the Nix
store.

The package binary itself must remain unwrapped. Client commands such as
`hyprvoice toggle`, `hyprvoice status`, `hyprvoice cancel`, and the niri binding
only talk to the daemon over Hyprvoice IPC; they do not need the OpenAI key and
should not receive it. Commands that can intentionally call provider APIs, such
as `hyprvoice test-models`, can get a separate explicit wrapper later if real
provider testing becomes part of the workflow.

The service wrapper should be private to the Home Manager module, not a general
package on PATH:

```nix
hyprvoiceServe = pkgs.writeShellScript "hyprvoice-serve" ''
  set -eu

  if [ -z "''${OPENAI_API_KEY:-}" ]; then
    OPENAI_API_KEY="$(${pkgs.gopass}/bin/gopass show -o openai/api-key)"
    export OPENAI_API_KEY
  fi

  exec ${hyprvoice}/bin/hyprvoice serve
'';
```

Then the user service runs only that private script:

```nix
systemd.user.services.hyprvoice.Service.ExecStart = "${hyprvoiceServe}";
```

The systemd user service needs the graphical session environment. CriomOS-home
already has a niri startup helper that imports display variables into the user
manager; extend that helper to include `XDG_RUNTIME_DIR` and `YDOTOOL_SOCKET`.
The service should also set `YDOTOOL_SOCKET=/run/ydotoold/socket` explicitly
when `programs.ydotool.enable` is the system path.

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

`ydotool` is the best typing backend to try first, but it depends on:

- the NixOS `ydotoold` service running;
- the user being in the configured `ydotool` group after a new login;
- `YDOTOOL_SOCKET` being visible to the Hyprvoice user service;
- the virtual keyboard layout producing the intended text under the configured
  niri/Colemak layout.

The clipboard backend in Hyprvoice `v1.0.2` only calls `wl-copy`. It copies the
transcript; it does not type text or trigger paste. Treat it as a recovery path,
not as the main typing backend.

## Implementation Order

1. Add the Hyprvoice source package to `CriomOS-home` and run the package checks
   with `CI=true`.
2. Add the `dictation` Home Manager module with OpenAI batch config and the
   systemd user service.
3. Enable `programs.ydotool` in CriomOS and extend horizon-built users with the
   configured ydotool group.
4. Add the niri `Mod+V` toggle binding.
5. Build and deploy through the normal lojix/CriomOS path, then log out and
   back in so the group membership and user manager environment are fresh.
6. Test three cases: plain English, mixed English with technical terms, and
   English with Sanskrit/IAST vocabulary in the Hyprvoice keywords list.
7. Only after explicit permission, run real OpenAI transcription tests.

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
- niri keybinding docs:
  <https://niri-wm.github.io/niri/Configuration%3A-Key-Bindings.html>
