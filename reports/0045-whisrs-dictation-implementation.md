# Whisrs Dictation Implementation

Research and implementation date: 2026-05-06.

This supersedes the active implementation shape from
[`0044-voxtype-dictation-trial.md`](0044-voxtype-dictation-trial.md).

## Decision

Use `whisrs` as the next daily dictation path on Niri.

The fit is better than Hyprvoice or Voxtype for this environment:

- Niri is an explicit upstream support target.
- Text insertion uses `uinput` plus XKB reverse lookup, which directly targets
  the Colemak/layout failure mode.
- OpenAI REST and OpenAI Realtime backends are supported. The initial CriomOS
  profile uses OpenAI REST with `gpt-4o-transcribe`.
- The daemon/CLI shape lets niri own the keybinding while only the daemon
  wrapper receives the OpenAI key.

## Implemented Shape

Home side, in `CriomOS-home`:

- `inputs.whisrs-src` pins upstream `whisrs` source.
- `inputs.crane` builds the Rust package.
- `packages/whisrs/default.nix` builds a cloud-only `whisrs` package with
  default features disabled.
- `packages/whisrs/privacy.patch` removes vendor API key environment variables
  after the daemon constructs its backend, so helper commands do not inherit
  the key.
- `whisrs.service` starts through a gopass wrapper that reads
  `openai/api-key` into `WHISRS_OPENAI_API_KEY`.
- `XDG_DATA_HOME` is pointed at `$XDG_RUNTIME_DIR/whisrs-data` for the daemon,
  so upstream transcript history is runtime-only.
- `notify = false`, so the upstream "Done: <preview>" notification path does
  not display dictated text.
- `Mod+V` toggles `whisrs`.
- `Mod+Shift+V` keeps Hyprvoice as fallback.

System side, in `CriomOS`:

- edge users join the `uinput` group.
- the `uinput` group is declared.
- bare-metal edge systems load the `uinput` kernel module.
- udev grants `/dev/uinput` group read/write access for `uinput`.

## Acceptance Checks

Before calling this done in daily use:

1. Build the pushed home package from origin with `--refresh`.
2. Build the pushed system target from origin with `--refresh`.
3. Activate system and home, then log out/in so the `uinput` group is present
   in the compositor and user manager credentials.
4. Confirm `systemctl --user is-active whisrs.service` returns active.
5. Dictate a short sentence into Codex and Claude/terminal clients.
6. Confirm no dictated text appears in `journalctl --user -u whisrs.service`.
7. Confirm whisrs history is under runtime state, not
   `~/.local/share/whisrs/history.jsonl`.
8. Tune `[input].key_delay_ms` only if a target drops characters.

No paid STT call was made while writing this report.

## Verification on 2026-05-06

- `CriomOS-home#whisrs` built successfully from pushed `origin/main` with
  `--refresh`; both `whisrs` and `whisrsd` are present.
- Direct `CriomOS#nixosConfigurations.target` build correctly failed without
  lojix-projected `horizon` and `system` inputs.
- `lojix-cli` `OsOnly ... Build` succeeded for `goldragon/ouranos` from
  `github:LiGoldragon/CriomOS/main`.
- `lojix-cli` `HomeOnly ... Activate` succeeded for user `li` from
  `github:LiGoldragon/CriomOS-home/main`; `whisrs.service` started and
  `whisrs status` returned `idle`.
- `lojix-cli` `OsOnly ... Switch` succeeded for `goldragon/ouranos`; the
  persistent system group now includes `li` in `uinput`, and `/dev/uinput` is
  owned by `root:uinput` with group read/write.
- The already-running shell, niri process, and user systemd manager still lack
  `uinput` in their live credentials. Log out and log back in before judging
  whisrs typing behavior from `Mod+V`.
- No paid STT call was made during verification.

## Sources

- Whisrs upstream: <https://github.com/y0sif/whisrs>
- Whisrs configuration docs:
  <https://github.com/y0sif/whisrs/blob/main/docs/configuration.md>
- Whisrs history source:
  <https://github.com/y0sif/whisrs/blob/main/src/history.rs>
- Whisrs daemon source:
  <https://github.com/y0sif/whisrs/blob/main/src/daemon/main.rs>
