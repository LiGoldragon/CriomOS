# LLM API key review

## Scope

Review of the recent deploy-surface cleanup, with focus on
`modules/nixos/llm.nix` and the move from a static `apiKey` in
`CriomOS-lib/data/largeAI/llm.json` to llama.cpp's `--api-key-file`.

## Findings

### 1. The service fails open when the key file is empty

`modules/nixos/llm.nix` creates `/var/lib/llama/api-key` as an empty runtime
file and only adds `--api-key-file` when that file is non-empty. At the same
time, the service binds to `::` and opens `cfg.serverPort` in the firewall.

That means a missing, empty, or failed secret deployment starts the router
without authentication. This is a poor default for anything meant to be
secret-managed. It is fine only if the intended policy is explicitly
"unauthenticated endpoint on this network".

Better shape: make authentication policy explicit. For example:

- `auth.mode = "disabled"`: no key file, no auth, deliberate.
- `auth.mode = "required"`: `ExecStartPre` checks the key file is non-empty;
  failure prevents the service from starting.
- `auth.mode = "optional"` only for temporary migration.

### 2. The hard-coded key path is not yet integrated with a Nix secret system

The current path, `/var/lib/llama/api-key`, is operationally simple but not
declaratively owned. A human or another service has to populate it out of band.
That is better than putting a secret in `llm.json`, but it is not yet a complete
NixOS secret-management design.

There is no current repo wiring for agenix, sops-nix, `systemd.credentials`, or
an environment-file provider. The module should grow an option such as
`apiKeyFile`, `apiKeyCredential`, or `auth.keyFile`, and a host-specific secret
module should provide the concrete file.

### 3. The flat key file scales to many tokens, not to policy

The pinned llama.cpp server parses `--api-key-file FNAME` as a newline-delimited
list. Every non-empty line becomes an accepted key. Requests may use either
`Authorization: Bearer <key>` or `X-Api-Key: <key>`.

That is enough for multiple clients and basic rotation:

- add a new key as another line;
- restart the service;
- migrate clients;
- remove the old line;
- restart again.

It does not provide key names, scopes, expiry, quotas, per-client logging, or
hot reload. If those become requirements, the correct scaling layer is a small
auth proxy or gateway in front of llama.cpp, not more Nix string shaping in the
model inventory.

### 4. `lojix eval` for Prometheus exposes an unrelated model-closure problem

The Prometheus LLM unit embeds the generated model directory into the start
script. Evaluating the toplevel drvPath for `goldragon/prometheus` currently
fails while checking the generated `llama-router-start` derivation because a
fetched model derivation is treated as a missing store path during eval.

This is tracked as bead `CriomOS-6z0`. The target-only lojix surface itself was
validated on `goldragon/ouranos`; the failure is specific to the largeAI model
closure design.

## How `--api-key-file` Works

`llama-server` keeps an in-memory vector of accepted API keys. The direct
`--api-key KEY` flag accepts a comma-separated list. The `--api-key-file FNAME`
flag opens the named file and appends every non-empty line to the same key list.

If that list is empty, llama.cpp skips authentication. If it is non-empty,
protected endpoints require a matching key. Public endpoints such as health and
model listing remain accessible without a key.

The recent CriomOS change uses the file form because the old design put
`apiKey` in shared model inventory JSON. That made secret material part of
cross-repo declarative data. A file path keeps the secret out of the Nix store,
out of `CriomOS-lib`, and out of the generated systemd command line.

## Why A Single File Flag Is The Right Primitive

The important primitive is not "one key"; it is "one secret-bearing file".
Upstream's file format already supports multiple keys by using one key per line.
The service only needs one argument because the file is the boundary where a
secret manager can write or mount the complete allow-list.

This is the right level for Nix:

- Nix should declare where the secret will appear and which service consumes it.
- The secret manager should own the bytes and permissions.
- llama.cpp should receive only a runtime path.

The model inventory file should continue to describe non-secret model policy:
models, context sizes, router limits, and load behavior. It should not carry
API tokens.

## Secret-Management Integration Shape

### agenix / sops-nix

A host-specific module can materialize a secret file under `/run/agenix/...` or
`/run/secrets/...` with owner `llama`, group `llama`, and mode `0400` or `0440`.
Then the LLM module should pass that path to `--api-key-file`.

The module should not create the secret itself. It should accept the path and
fail closed when auth is required and the file is missing or empty.

### systemd credentials

For tighter systemd integration, the unit can use `LoadCredential=` or
`LoadCredentialEncrypted=` and point llama.cpp at the per-unit credential path
under `$CREDENTIALS_DIRECTORY`. This avoids a stable service-owned secret path
in `/var/lib` and lets systemd handle credential staging.

This requires care because `ExecStart` needs to refer to a runtime environment
variable. The clean shape is an `ExecStart` wrapper that checks
`$CREDENTIALS_DIRECTORY/api-key` and then execs `llama-server
--api-key-file "$CREDENTIALS_DIRECTORY/api-key" ...`.

### Multiple Consumers

For a handful of clients, a newline-delimited allow-list is enough. For example,
one line for local tools, one for automation, one for a trusted remote client.
Rotation is an edit to the secret payload plus a service restart.

For many consumers or differentiated policy, do not stretch the llama.cpp key
file. Put an auth proxy in front, keep llama.cpp on a private listener, and let
the proxy own identities, scopes, logs, rate limits, and rotation.

## Recommended Follow-Up

1. Replace the implicit optional auth behavior with an explicit auth mode.
2. Add a module option for the key file or systemd credential source.
3. Wire Prometheus through the chosen secret manager, not `/var/lib` manual
   state.
4. Fix `CriomOS-6z0` so Prometheus can `lojix eval` without model derivation
   leakage.
