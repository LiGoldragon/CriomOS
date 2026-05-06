# Linux Dictation Current State

This report agglomerates and supersedes the STT/dictation report chain:

- `0042-linux-stt-typing-options.md`
- `0043-hyprvoice-openai-implementation.md`
- `0044-voxtype-dictation-trial.md`
- `0045-whisrs-dictation-implementation.md`

Those reports recorded the search path from general Linux STT research through
Hyprvoice, Voxtype, and finally Whisrs. Their useful conclusion is now compact:
Whisrs is the active daily dictation tool; the durable implementation lives in
CriomOS-home, while CriomOS owns the system access needed for `/dev/uinput`.

No paid STT or LLM API call was made while writing this consolidation.

## Current Decision

Use Whisrs as the daily dictation path on Niri.

The relevant fit:

- Niri is an explicit upstream support target.
- Text insertion uses `uinput` plus XKB reverse lookup, which directly targets
  the Colemak/layout failure mode that broke `ydotool`.
- OpenAI REST and OpenAI Realtime backends are supported. The active profile
  uses OpenAI REST with `gpt-4o-transcribe`.
- The daemon/CLI shape lets niri own the keybindings while only the daemon
  wrapper receives the OpenAI key.

Hyprvoice and Voxtype are no longer active profile paths. They remain useful
historical comparisons, not current implementation records.

## Why Hyprvoice Stopped

Hyprvoice proved that OpenAI STT quality was not the main problem. The failure
surface was desktop insertion:

- `ydotool type` sent physical key positions, which niri interpreted through
  the active Colemak layout.
- Hyprvoice's `wtype` backend avoided that layout failure, but receiver-specific
  tests still dropped spaces.
- Adding key delay made long dictation unpleasantly slow and still did not give
  a principled guarantee for raw terminal or assistant clients.
- A long dictation run appeared to send Enter/control input into Codex, which
  made character-stream insertion unacceptable for long assistant prompts.

The Hyprvoice credential research remains valid as a general warning:
environment variables are a broad secret boundary for long-running services
whose child processes inherit the environment. CriomOS-home's current Whisrs
wrapper narrows the practical exposure by clearing vendor key variables after
Whisrs constructs the backend.

## Why Voxtype Stopped

Voxtype was a reasonable trial because it made output policy explicit and had
paste-oriented long-text behavior. It was not the best final fit:

- its best reliable long-text path centered clipboard/paste transport;
- it did not solve the self-insertion model as cleanly as Whisrs's uinput/XKB
  path;
- adopting it would have meant carrying source patches before the tool had
  proved itself as the daily interface.

## Implemented Shape

Home side, in CriomOS-home:

- `inputs.whisrs-src` pins upstream Whisrs.
- `inputs.crane` builds the Rust package.
- `packages/whisrs/default.nix` builds a cloud-oriented Whisrs package with
  the tray feature enabled.
- `packages/whisrs/privacy.patch` removes vendor API key environment variables
  after the daemon constructs its backend, so helper commands do not inherit
  the key.
- `packages/whisrs/clipboard-mode.patch` adds `whisrs toggle-copy`.
- `packages/whisrs/transcript-recovery.patch` copies successful direct
  dictation transcripts to the clipboard before keyboard insertion.
- `packages/whisrs/tray-icon-theme.patch` makes the tray item expose
  state-specific icon files for Noctalia.
- `whisrs.service` starts through a gopass wrapper that reads
  `openai/api-key` into `WHISRS_OPENAI_API_KEY`.
- `Mod+V` toggles direct dictation.
- `Mod+Shift+V` toggles clipboard-only dictation for apps that mishandle direct
  key injection.
- Transcript history is explicit local app state at
  `~/.local/share/whisrs/history.jsonl`; the wrapper creates the directory
  private and the file mode `0600`.
- Noctalia pins the Whisrs tray item inline so recording state is visible.

System side, in CriomOS:

- edge users join the `uinput` group;
- the `uinput` group is declared;
- bare-metal edge systems load the `uinput` kernel module;
- udev grants `/dev/uinput` group read/write access for `uinput`.

## Current User Contract

- `Mod+V`: transcribe, put the final transcript on the clipboard, then type it
  through uinput into the focused app.
- `Mod+Shift+V`: transcribe and put the final transcript on the clipboard
  without typing.
- `whisrs log -n 20`: inspect recent transcript history.
- `whisrs status`: inspect daemon state.
- `whisrs cancel`: stop a recording without transcription.

The clipboard backup is deliberate recovery state. The durable history is also
deliberate recovery/introspection state. This reverses the earlier trial policy
that normal dictation history should be runtime-only.

## Verification Status

Verified on 2026-05-06:

- `CriomOS-home#whisrs` built successfully from pushed origin with
  `--refresh`.
- `HomeOnly ... Activate` succeeded through lojix and restarted
  `whisrs.service`.
- `whisrs.service` is active and `whisrs status` returns `idle`.
- Whisrs uses `XDG_DATA_HOME=/home/li/.local/share`.
- `~/.local/share/whisrs/history.jsonl` exists with mode `0600`.
- Existing runtime history was migrated into the durable history file.
- Whisrs tray metadata advertises state-specific icon files that exist.
- A record/cancel probe changes tray state without making a paid STT call.

No current verification depends on literal store paths.

## Remaining Risks

- The current configured backend is OpenAI REST. Realtime/streaming mode should
  be re-audited before activation because upstream streaming code logs typed
  deltas.
- The durable history file intentionally stores dictated text. Agents may refer
  to it when the user asks for recovery, but it is private local user data, not
  journal output or a shared workspace artifact.
- Some receiver applications still mishandle direct synthetic input. Use
  `Mod+Shift+V` for clipboard-only recovery in those apps.
- System group changes require a fresh login before the compositor and user
  manager have the new credentials.

## Canonical Pointers

- CriomOS-home's `skills.md`: user-side dictation ownership and current Whisrs
  workflow.
- CriomOS's `skills.md`: system/home boundary and `/dev/uinput` ownership.
- primary's `skills/stt-interpreter.md`: how agents should read
  STT-transcribed prompts.
- Whisrs upstream: <https://github.com/y0sif/whisrs>
