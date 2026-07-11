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

## Source-ready pin preflight

Before live cutover, machine-check the deployment lock chain is exactly:

- `signal-spirit-judge` `7c25b71a34858c0d912dff8fd0b4f4ac213d7cd1`;
- `spirit-judge` `c2303a30ff88fea527a8075b22f1d598a80fdb80`;
- `spirit-judge-config` `b6a3fe7e0f91f2e5ff8ddec94ebfe2b489fc355d`;
- `spirit` `f9f5266abec8a0bcf43b8bcc93cf066aa9f97ea2`; and
- `CriomOS-home` `8cc609ebc2c5f145024510bd3fdbd7cd9f406f67`.

The Home fake deployment check proves only rendered service wiring and argv.
The separate `spirit-judge-cli-contract` check invokes the real package's
unauthenticated usage boundary; neither check authenticates or calls a model.

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

Use the locked Nix package rather than an ad-hoc Cargo project for every live
component witness. The command accepts only a running typed judge socket and
sends its own synthetic, public, non-database admission packet. For Luna, the
socket must belong to an isolated judge process built from the same immutable
package and configured with the approved Luna model; it must not be the Spirit
daemon or open the production store. For Terra after activation, use the managed
judge socket.

```sh
nix run --max-jobs 1 --cores 1 \
  github:LiGoldragon/spirit-judge/c2303a30ff88fea527a8075b22f1d598a80fdb80#witness -- \
  --socket "$SPIRIT_JUDGE_WITNESS_SOCKET" \
  --model gpt-5.6-luna --effort medium \
  --revision c2303a30ff88fea527a8075b22f1d598a80fdb80

nix run --max-jobs 1 --cores 1 \
  github:LiGoldragon/spirit-judge/c2303a30ff88fea527a8075b22f1d598a80fdb80#witness -- \
  --socket "$HOME/.local/state/spirit/spirit-judge.sock" \
  --model gpt-5.6-terra --effort medium \
  --revision c2303a30ff88fea527a8075b22f1d598a80fdb80
```

The witness emits only parsed verdict class, model, effort, revision, and exit
status. Treat a nonzero exit or `request-rejected`/`unavailable` class as a
failed gate without preserving any additional output.

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
