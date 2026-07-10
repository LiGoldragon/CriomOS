# Spirit judge cutover and rollback

## Purpose

This runbook changes the fail-closed Spirit judge path without exposing prompts,
records, diagnostics, or credential material. `signal-spirit-judge` is the typed
wire contract, `spirit-judge` is the socket executable, `judge` owns provider
mechanics, and `spirit-judge-config` is public declarative prompt and catalogue
data.

## Pin and build order

1. Land and push contract/provider producers.
2. Land and push `spirit-judge`; verify its Cargo lock pins the provider commit.
3. Land and push `spirit-judge-config` policy/documentation.
4. Update and validate the `CriomOS-home` lock, where the actual Nix service
   arguments select provider, model, effort, timeout, and authorization mode.
5. Update and validate this deployment flake lock to the exact Home commit.
6. Deploy only the pushed immutable deployment revision through Lojix.

The catalogue policy file is declarative. The Home service command is the
operative selection source and must be inspected or tested for the exact
`openai-codex`, model, effort, timeout, and external-session reference.

## Authorization and provider witnesses

`codex-login` means the configured Codex executable's pre-existing ambient
session. It is not a bearer secret and does not select an account. Before
activation, obtain authority that the ambient session is the intended account
through an approved non-secret status interface. If that cannot be bounded, keep
both `spirit-judge` and its dependent `spirit-daemon` stopped.

For Luna compatibility and Terra production witnesses, record only:

- timestamp;
- executable revision;
- model and effort;
- exit status; and
- parsed verdict class.

Do not retain prompts, record text, provider output, diagnostics, account data,
or credentials. Run fake-executable tests for argv/auth/timeout mechanics and
use at most one approved authenticated call for each live model witness.

## Database safety

Before deployment, create a byte-preserving private backup of the production
store and verify it without reading records. On the live store, use only a
marker query. A stable `(commit-sequence state-digest)` marker is evidence that
the committed record and referent corpus is unchanged even when database pages
are rewritten after restart. Keep the backup through acceptance. Accepted-write
checks belong only to a private exact copy or a supported reversible namespace.

## Activation and fail-closed checks

Deploy with `ActivateNow` using the immutable deployment revision, then confirm
Lojix reports a new `Current` generation. Verify both services are active and
the live judge process argv has the pinned executable plus the exact provider,
model, effort, timeout, and external-session reference. Restart the judge and
confirm its dependent Spirit service returns active; unavailable, malformed,
timeout, and provider failures must remain typed rejections before any write.

## Rollback

If the judge cannot authenticate, start, or satisfy the fail-closed checks, stop
`spirit-judge.service`; its required Spirit dependency must not provide a write
path. Re-activate the prior known-good immutable CriomOS deployment revision
through Lojix, wait for it to become `Current`, and verify the previous service
argv and marker. Do not restore the production database merely because its bytes
differ after a restart; restore only from the preserved backup under explicit
recovery authority and after comparing the logical marker.
