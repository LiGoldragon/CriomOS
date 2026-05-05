# Dictation Output Tool Review

Research date: 2026-05-05.

This follows [`0043-hyprvoice-openai-implementation.md`](0043-hyprvoice-openai-implementation.md).
Initial implementation avoided paid STT calls. After reviewing the wider
Linux/Niri dictation landscape, do not treat Voxtype as the final destination.

## Hyprvoice Decision

Stop widening the Hyprvoice output patch set. Keep the current Hyprvoice home
profile as a fallback for contexts where it works, but move the next
OpenAI-backed dictation trial away from Hyprvoice.

The reason is not OpenAI speech-to-text quality. The failure surface is the
desktop insertion layer:

- `ydotool type` fails under the active Colemak environment because it sends
  physical key positions that niri interprets through the configured layout.
- Hyprvoice's `wtype` backend fixed that class of layout failure, but live use
  still dropped spaces in some receivers.
- Increasing synthetic key delays made long dictation unpleasantly slow and
  still did not give a principled guarantee against receiver-sensitive event
  loss.
- A long dictation run appeared to submit text in multiple prompts. Whether
  that came from newline/control text or key-event behavior, char-by-char
  injection is the wrong transport for long assistant prompts.
- Hyprvoice's upstream output surface is `ydotool`, `wtype`, and clipboard.
  The safer long-text behavior we now need would be a local policy layer, not
  a small packaging fix.

## Voxtype Assessment

Voxtype was a reasonable next trial because it already treats output as a
policy choice:

- It is packaged in nixpkgs.
- It supports compositor-controlled recording commands, so niri can own the
  binding and Voxtype's evdev hotkey stays disabled.
- It has explicit `type`, `clipboard`, and `paste` output modes.
- Paste mode copies text, sends a paste chord, and can restore the previous
  clipboard after the target receives the paste. In this trial the clipboard
  is transport, not the user-facing result.
- It supports remote OpenAI-compatible transcription endpoints, including an
  API key from `VOXTYPE_WHISPER_API_KEY`.
- It exposes driver ordering and `dotool_xkb_layout` for a future typed-output
  trial if a uinput-backed path becomes acceptable.

However, it is not obviously the best Linux/Niri option:

- The reliable long-text path is clipboard-backed paste. That may be acceptable
  as transport, but it is not the cleanest fit for a user who wants real typing
  semantics and dislikes clipboard-centered workflows.
- The upstream daemon logs transcript content by default at normal log levels;
  our package override redacts that, but it means we carry source patches before
  we have proved this is the winning tool.
- The upstream restore path restores a non-empty clipboard, but an originally
  empty clipboard remains populated with dictated text unless we add another
  patch or upstream changes behavior.
- Its key advantage over Hyprvoice is paste policy, not a fundamentally better
  Niri/Colemak typing model.

That makes Voxtype a fallback/trial candidate, not the “best pick” to bet the
workflow on.

## Whisrs Assessment

`whisrs` is the stronger current candidate for this environment.

Observed from upstream documentation and source review:

- It explicitly supports Niri and is reported tested by a contributor on Niri.
- It supports OpenAI REST and OpenAI Realtime transcription backends.
- It uses `uinput` plus XKB reverse lookup for text insertion, directly
  addressing the Colemak/layout class of bug that hit `ydotool`.
- It exposes `key_delay_ms` for TUI receivers that drop fast synthetic input.
- It has a daemon/CLI shape, so niri can own the compositor keybinding.
- It ships a Nix flake and installs udev/systemd support.

Risks to fix before adopting:

- It writes successful transcriptions to
  `~/.local/share/whisrs/history.jsonl` by default. That conflicts with the
  “dictation should not persist normal text” policy unless disabled or patched.
- Debug logs can include transcript fragments and selected text in command mode.
  Run at info level and avoid command mode, or patch if we need stronger
  guarantees.
- It needs `/dev/uinput` access. The existing `input` group/system udev work is
  compatible with that requirement, but it is still a system surface.
- OpenAI Realtime may improve UX, but it is billed differently than the REST
  transcription endpoint and should be tested deliberately.

Recommended next step: pause Voxtype activation and package/configure `whisrs`
as the next trial, with history disabled/redacted before first daily use. Keep
Hyprvoice on `Mod+V` as a fallback until the new path proves itself; put
`whisrs` on a separate binding.

## Implemented Voxtype Trial Shape

`CriomOS-home` now packages Voxtype through a local override:

- `packages/voxtype/default.nix`
- `packages/voxtype/privacy.patch`

The privacy patch does two things:

1. Redacts upstream transcript-content logs. Voxtype otherwise logs full
   transcriptions and post-processed text at info/debug level, which would
   persist normal dictation in the user journal when run as a user service.
2. Removes `VOXTYPE_WHISPER_API_KEY` from the process environment after the
   key has been copied into the loaded config, so output helper commands do not
   inherit the API key.

The Home Manager dictation profile now keeps Hyprvoice on `Mod+V` and adds
Voxtype on `Mod+Shift+V`.

Voxtype service shape:

- user service: `voxtype.service`
- daemon wrapper: reads `gopass openai/api-key`
- only the daemon wrapper receives `VOXTYPE_WHISPER_API_KEY`
- built-in Voxtype hotkey disabled
- niri binding calls `voxtype record toggle`

Voxtype config shape:

```toml
engine = "whisper"
state_file = "auto"

[hotkey]
enabled = false
mode = "toggle"

[whisper]
mode = "remote"
remote_endpoint = "https://api.openai.com"
remote_model = "gpt-4o-transcribe"
language = "en"
translate = false
remote_timeout_secs = 120

[output]
mode = "paste"
fallback_to_clipboard = false
auto_submit = false
append_text = " "
shift_enter_newlines = false
paste_keys = "ctrl+v"
restore_clipboard = true
restore_clipboard_delay_ms = 500

[output.notification]
on_recording_start = true
on_recording_stop = true
on_transcription = false

[text]
spoken_punctuation = false
smart_auto_submit = false
```

## Acceptance Criteria For Any Replacement

This trial is accepted only if:

1. Long dictated prompts insert as one target-side paste operation rather than
   slow synthetic character streaming.
2. No accidental Enter/submit behavior appears with normal prose dictation.
3. It does not persist dictated text in history files, normal service logs, or
   notifications.
4. The user journal contains status, timing, and character counts, not dictated
   text.
5. The OpenAI key is not present in normal control-command invocations or
   output helper child environments.

If `whisrs` fails those checks, the next step is not more Hyprvoice tuning. The
next step is a small CriomOS-owned dictation tool with explicit nouns for
capture, transcription, insertion, credential loading, and log policy.

## Sources

- Hyprvoice output backends:
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/wtype.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/ydotool.go>,
  <https://github.com/LeonardoTrapani/hyprvoice/blob/v1.0.2/internal/injection/clipboard.go>
- Voxtype configuration and output docs:
  <https://github.com/peteonrails/voxtype/blob/main/docs/CONFIGURATION.md>,
  <https://github.com/peteonrails/voxtype/blob/main/README.md>
- Voxtype source inspected through the pinned nixpkgs package:
  `src/output/paste.rs`, `src/output/mod.rs`, `src/transcribe/remote.rs`,
  `src/daemon.rs`, `src/main.rs`
- Whisrs docs and source:
  <https://y0sif.github.io/whisrs/>,
  <https://github.com/y0sif/whisrs/blob/main/docs/configuration.md>,
  <https://github.com/y0sif/whisrs/blob/main/src/history.rs>,
  <https://github.com/y0sif/whisrs/blob/main/src/daemon/main.rs>
- OpenAI speech-to-text guide:
  <https://platform.openai.com/docs/guides/speech-to-text>
