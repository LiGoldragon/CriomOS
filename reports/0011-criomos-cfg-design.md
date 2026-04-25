# criomos-cfg — managed-mutable config merge with drift feedback

Status: **DESIGN, deferred**. Not implemented. Tracked as a side-repo
bead. Pick up after Phase 8 module wiring completes.

## Problem

Many config files are *managed defaults + room for local override*:
vscodium `settings.json`, mentci-cli MCP config, eventually
`sshd_config`, `mpv.conf`, `niri.kdl`, `~/.gitconfig`, etc.

Two things we want:

1. **Correct merge**: nix-derived defaults install, *user edits in
   nested objects survive*. Today's `mkJsonMerge` does `jq -s '.[0] *
   .[1]'` which is a shallow merge — nested-object user tweaks (e.g.
   `"[python]": { wordWrap = "on" }`) get clobbered by the nix side.
2. **Visibility into user drift**: when a user persistently overrides
   `editor.tabSize=2`, that's signal — should `user.preferredIndent`
   become a horizon-rs field?

No existing tool does both. `home-manager` activation works above
file-key granularity. `chezmoi merge` is 2-way interactive across
machines. `etckeeper` is git-audit. `dconf` is layered but
GNOME-specific.

## Tool shape

A small Rust CLI, single binary, sub-commands:

```
criomos-cfg apply    --file PATH --declared FILE [--snapshot DIR]
criomos-cfg diff     --file PATH [--snapshot DIR]
criomos-cfg snapshot --file PATH --to FILE
```

Three states per managed file:

```
declared   = what nix wants installed this activation (immutable input)
snapshot   = what we wrote last activation (state file we own)
live       = what the editor / app actually reads (mutable user file)
```

`apply` performs:

1. Read declared, snapshot, live as JSON values.
2. Compute `user_drift = json_merge_patch(snapshot → live)` — what
   the user changed since our last write.
3. Compute new live = `deep_merge(declared, user_drift)` —
   declared keys win unless the user explicitly drifted them.
4. Atomically write new live (`tempfile + persist`).
5. Update snapshot to declared.
6. Emit drift report to `~/.local/state/criomos/drift/<file-id>.json`
   (timestamped) for later inspection.

`diff` is read-only — show user_drift without applying.

`snapshot` is an escape hatch — manually capture current live as the
new baseline (used when adopting a previously-unmanaged file).

## File-id

Hash of the live file path. e.g.
`sha256("~/.config/VSCodium/User/settings.json")[..6]` → 6-char id.
Snapshots and drift live at `~/.local/state/criomos/{snapshot,drift}/<id>.json`.

## Format coverage (phased)

- **v1**: JSON only. Covers vscodium + mentci-cli + most modern
  editor/tooling configs.
- **v2**: TOML (cargo / `~/.gitconfig`). `serde_toml` preserves
  ordering via `indexmap`.
- **v3**: YAML (k8s-adjacent stuff if it ever appears in user-facing
  CriomOS scope).
- **deferred**: KDL, INI, app-specific DSLs (mpv.conf, sshd_config) —
  add when a real consumer needs them. Each requires a parser that
  preserves comments + ordering.

## Diff representation

**JSON Merge Patch (RFC 7396)** for drift reports. Reasons:
- Reads like a partial config — `{ "editor.tabSize": 2 }` is
  unambiguous and reviewable.
- Symmetric: applying the patch to snapshot reconstructs live.
- Trivially diffable across activations to track *evolution* of
  user drift.

JSON Patch (RFC 6902) is more expressive (move, copy, test ops) but
verbose for the audit-this-by-eye use case.

## Risks (and how each is handled)

| Risk | Plan |
|------|------|
| Nested arrays — declared has `[{id: a}]`, live has `[{id: a}, {id: b}]` — does b survive? | v1: replace arrays wholesale (declared wins). v2: schema hints in declared overlay (`_criomos_array_keyed_by: id`) for keyed-merge semantics. |
| Ordering preservation in TOML / YAML | Use `indexmap`-backed parsers. Keep round-trip in `Value` form, never deserialize-into-struct. |
| Comments in source files | v1 assumes comment-free managed configs. Document the limitation. v3+ would need format-preserving parsers (e.g. `taplo` for TOML). |
| First activation (no snapshot exists) | Treat live as the snapshot baseline. Drift = empty. Subsequent activations track from there. |
| User edits during activation race | Lock the live file (advisory `flock`) for the read-merge-write window. Single-shot, sub-100ms. |
| Drift report grows unbounded | Rotate: keep last N drift snapshots per file (configurable, default 30). |

## Integration with home-manager

Replace today's `mkJsonMerge` helper with a thin wrapper:

```nix
mkManagedConfig = { file, declared }:
  lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.criomos-cfg}/bin/criomos-cfg apply \
      --file "${file}" \
      --declared ${pkgs.writeText "declared.json" (builtins.toJSON declared)}
  '';
```

VSCodium specifically should use VSCode's native `User/` vs
`Workspace/` settings split (zero merge needed). Use `mkManagedConfig`
for everything else.

## Drift → CriomOS dial pipeline (the killer feature)

A nightly (or on-demand) `criomos-cfg report` command aggregates
drift across files and across nodes (assuming we sync drift state to
a central store). Output: a ranked list of "settings users override
most often". Each high-frequency override is a candidate for a real
horizon-rs field.

Manual workflow at first — read the report, decide which to promote.
Later, an LLM-assisted suggester ("based on your drift, consider
adding `user.preferredIndent: Int`").

## Out of scope (v1)

- Format conversion (read JSON, emit YAML, etc.)
- Conflict resolution UI — declared always wins on conflict; user
  drift only survives where declared is silent
- Sync of drift state across nodes — local-only initially
- Schema validation / linting

## Estimate

500–800 LOC Rust. ~2 days of focused work for v1. Critical path:
serde_json deep merge + atomic write + snapshot lifecycle. Drift report
is straightforward once the merge core is solid.

## Open questions

- **Q1**: Sync drift state to a central store eventually? If yes, where
  — a goldragon-style nota file, a CRDT, a simple rsync target?
- **Q2**: Should declared overlays be allowed to *delete* keys from
  live (RFC 7396 supports `null` to delete)? My instinct: yes,
  declared is the source of truth for shape.
- **Q3**: For files with no snapshot (first run on a long-lived live
  file), do we adopt live as-is or warn? My instinct: adopt silently
  on first run, log a one-time message.
- **Q4**: Is there value in a `--dry-run` for `apply` that prints the
  diff it *would* write? Probably yes, very cheap.

## References

- [JSON Merge Patch RFC 7396](https://datatracker.ietf.org/doc/html/rfc7396)
- [JSON Patch RFC 6902](https://datatracker.ietf.org/doc/html/rfc6902)
