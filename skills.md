# Skill — CriomOS

*Working effectively in the host-OS platform repo.*

---

## What this skill is for

Use this when changing NixOS-level behavior for the sema desktop and
cluster platform: users, groups, devices, modules, services, deploy
surface, and the meta-repo symlink workspace.

CriomOS is the host OS target. It exposes `nixosConfigurations.target`
and stays network-neutral. Cluster, node, user, and deployment identity
arrive through lojix-projected `horizon`, `system`, and `deployment`
flake inputs.

---

## Start here

Read `AGENTS.md`, lore's `AGENTS.md`, criome's `ARCHITECTURE.md`,
`ARCHITECTURE.md`, and `docs/ROADMAP.md` before editing. If working from
the primary workspace, also follow its `skills/autonomous-agent.md` and
claim the repo with the operator lock.

Run `bd list --status open` first. Keep reports as decision records and
move durable guidance into docs, AGENTS, architecture, skills, or code.

---

## Boundaries

This repo owns:

- NixOS modules under `modules/nixos/`.
- The single public system surface, `nixosConfigurations.target`.
- The cluster meta-repo view under `repos/`.
- System prerequisites for user-space tools, such as groups, udev rules,
  kernel modules, and system services.

This repo does not own:

- Home Manager profile implementation; that lives in CriomOS-home.
- Horizon schema or projection logic; that lives in horizon-rs.
- Rust application crates; package or consume them as flake inputs.
- Node or cluster literals in modules.

---

## System/Home Split

When a feature crosses desktop and system boundaries, keep ownership
sharp.

For Whisrs dictation:

- CriomOS-home owns the Whisrs package, service wrapper, Niri bindings,
  Noctalia tray visibility, clipboard behavior, and transcript history.
- CriomOS owns `/dev/uinput` access: user group membership, the `uinput`
  group, the bare-metal kernel module, and udev permissions.

Do not patch around missing system credentials in home code. If a
running session does not have a new group, the durable fix is a system
activation plus a fresh login.

---

## Nix and Deploy

Module logic reads projected horizon fields directly. If the needed
truth is missing, extend horizon-rs instead of encoding a local
workaround.

Build and activate through lojix-projected inputs for real checks. A
plain direct build of `nixosConfigurations.target` without projected
`horizon` and `system` inputs is not the real deploy path.

Push before build/switch work. Capture store paths in shell variables,
not prose. Keep niri unsignalled.

---

## See also

- CriomOS-home's `skills.md` for user-side desktop and STT work.
- primary's `skills/autonomous-agent.md` for operator workflow.
- primary's `skills/skill-editor.md` for editing this file.
- lore's `AGENTS.md` for the workspace contract.
