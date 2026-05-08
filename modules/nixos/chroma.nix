# Chroma — system-level wiring for the visual-state daemon.
#
# CriomOS-home runs the daemon and CLI as per-user processes
# (modules/home/profiles/min/chroma.nix in CriomOS-home). The
# system side does two things:
#
#   1. declare the `chroma` group, used to gate which users can
#      bind / connect to the daemon's UDS;
#   2. create a group-controlled `/run/chroma/` directory at boot
#      so each user's `chroma-daemon` can drop a per-uid socket
#      inside (`/run/chroma/<uid>.sock`).
#
# Membership in the `chroma` group is auto-granted to graphical
# users in `modules/nixos/users.nix` via the `behavesAs.edge`
# trust flag. Server-only users (no graphical session) are kept
# out by the directory permission alone.
{
  ...
}:
{
  users.groups.chroma = { };

  # /run/chroma/ is the system-managed home for chroma's
  # per-user UDS sockets. Mode 0770 root:chroma — non-group
  # users can't even enter the directory, so cannot connect to
  # any user's chroma daemon.
  systemd.tmpfiles.rules = [
    "d /run/chroma 0770 root chroma -"
  ];
}
