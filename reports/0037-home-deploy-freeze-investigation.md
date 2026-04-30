# Home Deploy Freeze Investigation

## Incident

On 2026-04-30, a manual home-only deployment was applied on `ouranos`
because `lojix-cli` has the design for home-only deploy tracked in
`CriomOS-4yt` but no implemented `--home-only` mode yet.

The manual path built
`nixosConfigurations.target.config.home-manager.users.li.home.activationPackage`,
set `~/.local/state/nix/profiles/home-manager` to the new generation,
and ran the generated `activate` as user `li`.

Shortly after activation, the graphical session froze hard enough that
Li used the power key repeatedly and rebooted.

## Persisted Log Timeline

Previous boot `-1`:

- Start: 2026-04-28 10:04:14 CEST.
- End: 2026-04-30 16:20:39 CEST.

Current boot `0`:

- Start: 2026-04-30 16:21:14 CEST.

Relevant previous-boot events:

- 16:18:36-16:19:06: `nix-daemon` accepted multiple connections from
  user `li`, matching the manual deployment.
- 16:19:05.862: session `dbus-broker` noticed filesystem changes and
  rescanned service files.
- 16:19:06.025: `niri` loaded `/home/li/.config/niri/config.kdl`.
- 16:19:06.031: `niri` reported `listening on X11 socket: :0`.
- 16:19:06.969: user systemd reload requested by `sd-switch`.
- 16:19:07.061: `blueman-applet.service` rejected because it had more
  than one `ExecStart=`.
- 16:19:08.128: `darkman.service` stopped and restarted.
- 16:20:26, 16:20:30, 16:20:34, 16:20:36, 16:20:39: repeated short
  power-key presses.

`journalctl -k -b -1` for 16:00-16:21 had no entries. There is no
persisted evidence of a kernel panic, OOM kill, or GPU reset in that
window. On the next boot, journald reported the user journal was
uncleanly shut down, which fits a forced power-off/reboot after a
frozen session.

## Generation Diff

Home Manager generation 594 changed the niri config relative to 593:

- Added a Solar Fire window rule.
- Added `xwayland-satellite { path ... }`.

No user systemd unit files in the checked set changed between 593 and
594.

The current boot is internally inconsistent:

- `~/.local/state/nix/profiles/home-manager` points at generation 594.
- `/home/li/.config/niri/config.kdl` does not contain the generation
  594 `xwayland-satellite` block.
- Boot-time `hm-activate-li` ran from the NixOS system generation and
  re-linked home files from the system's older pinned `criomos-home`.

This means the manual home-only profile activation is not persistent
across reboot when Home Manager is also embedded in the NixOS system:
the next system boot activation reasserts the system generation's home
files, while the standalone HM profile symlink can still point at the
manual generation.

## Working Hypothesis

The most likely immediate trigger was live niri config reload during
Home Manager activation, specifically adding the Xwayland integration
while the session was already running.

That is supported by the tight sequence:

1. HM relinked `.config/niri/config.kdl`.
2. `dbus-broker` rescanned services.
3. `niri` live-reloaded config.
4. `niri` enabled X11 socket integration.
5. `sd-switch` reloaded the user systemd manager.
6. `darkman` restarted.
7. The session became unusable within about a minute.

Upstream niri docs explicitly state that config is live-reloaded, and
that xwayland-satellite integration creates X11 sockets and spawns the
satellite on demand. The logs show exactly that transition happening
inside an already-running session.

The broken `blueman-applet.service` is real but is likely a secondary
fault: it is still broken after reboot, yet the session is usable.

Upstream references:

- <https://github.com/YaLTeR/niri/wiki/Configuration%3A-Introduction>
- <https://github.com/YaLTeR/niri/wiki/Xwayland>

## Implications

The `CriomOS-4yt` home-only design needs a guardrail: home-only deploy
must distinguish file-only activation from live session mutation.
For niri sessions, changing compositor config or graphical-session
services is not operationally equivalent to a harmless home switch.

Practical rule until this is implemented:

- Do not run live manual HM activation for changes touching niri,
  noctalia, graphical-session units, D-Bus service exposure, portals,
  darkman, or wl-gammarelay.
- For those changes, deploy through the full system path with `boot`
  or implement a home-only mode that can build and register the
  generation without live reloading the running graphical session.
