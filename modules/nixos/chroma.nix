# Chroma — legacy system-level compatibility.
#
# CriomOS-home runs the daemon and CLI as per-user processes
# (modules/home/profiles/min/chroma.nix in CriomOS-home). Current
# Chroma uses the normal per-user socket at
# `$XDG_RUNTIME_DIR/chroma.sock`.
#
# This module is retained only so old home-manager generations that
# still point at `/run/chroma/<uid>.sock` have a migration runway.
# Do not add new Chroma clients to this directory; remove this module
# after the socket-path migration has landed everywhere.
{
  ...
}:
{
  users.groups.chroma = { };

  # Legacy socket directory for pre-migration Chroma generations.
  # Current Chroma defaults to `$XDG_RUNTIME_DIR/chroma.sock`.
  systemd.tmpfiles.rules = [
    "d /run/chroma 0770 root chroma -"
  ];
}
