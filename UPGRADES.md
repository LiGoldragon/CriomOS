# Breaking upgrades

## Claude Fable 5.1 and Codex 0.152.1 Home consumer

This consumer advances CriomOS-home to
`90a12633cc60148b62bc47fd44957e6165727094`. It updates the declarative
Claude Code package, Claude Desktop package, managed Claude Code VSIX, Codex,
and ChatGPT Desktop surfaces as one producer revision. Use the materialized consumer output
`homeConfigurations.<user>.activationPackage`, first realize it through the
typed Lojix user-environment surface, and only then use the separately
authorized least-disruptive activation action.

Activation does not replace a running Claude Desktop process or migrate live
Claude/Codex remote-control clients. Do not restart GUI applications as part
of the deployment. Confirm the activated profile and remote-control owners
afterward; a fresh Claude Desktop launch is required to load the upgraded
Desktop package. The new Claude Code model remains selectable per new session
as `claude-fable-5-1`; do not force a global model setting.

## Flow identity helper Home consumer

CriomOS consumes CriomOS-home
`c8bbc9dacd87b594851a70800b5f190674f7da3e`, whose locked Harness input is
`363a5bec61d05a628750e00e7b03d8de7f8693a8`. Claude parent flows now require
the explicit `flow-id claude --flows-root /absolute/flows-root --parent-session
UUID` form, accept only canonical lowercase RFC 4122 UUIDv4 parents, and begin
with the parent's first six literal hexadecimal characters. The user-environment deployment
output remains this consumer's materialized
`homeConfigurations.<user>.activationPackage`; do not substitute a standalone
Home configuration. Deploy only the pushed immutable CriomOS revision through
an explicit Lojix `UserEnvironment` request, then separately witness the
profile and executable path.

## Orchestrate 0.26.0 Home consumer

This consumer advances CriomOS-home to `0530bcd80cce53bcd876f9ecf5947ed43698a2b4`
and follows its immutable Orchestrate
`dadd537bbd2ed2ffc5260fffc5735f9f020cc774` pin. The Home unit remains the
sole declarative owner of the zero-argument `orchestrate-nexus` process and
its standard XDG state and socket paths; do not edit or restart the unit by
hand as a substitute for a Home generation activation.

The 0.26 WireContract replacement is breaking for both sockets. Follow the
Home upgrade record: stop the old Nexus only under approved activation
authority, run the candidate preflight against the same state root, proceed
only with zero legacy rows, and activate the matching clients and Nexus
together. Its Sema schema/families are unchanged, so rollback is the preceding
immutable Home generation with its matching 0.25 wrappers—not a store copy or
a mixed-client restart.

This is the canonical CriomOS procedure for breaking Lojix deployment
contracts. Producer and consumer source remains authoritative for the
contract; this file records only the crossing order, gates, and recovery
boundary. Correct this procedure from evidence before any retry after a
failure or partial activation.

## primary-99n — remove Agent Intercom node-service gates

Deploy only after the consumer chain uses Horizon
`c70915eb550f729996e0921069b34d7844c9b2e9` (0.4.0), Goldragon
`5bc563bf9507b65a8b6ab5cf537ee6413a96a4ca`, and Lojix
`33b8b6b7e5f893278a27c77130e8542072addda0`; the latter pins the new
Horizon schema. This revision pins CriomOS-home
`ed6832cf59b492601b3cdff4710751b8d1b02832`. Neither consumer provides a
compatibility path for the removed proposal values: Agent Intercom wrappers
are independent of node services, while Edge and metal retain ownership of
graphical facilities.

Evaluate the immutable source through Lojix's materialized inputs before a
realization. Stop on a producer/consumer revision mismatch; do not restore the
removed values or introduce a renamed composite. Activation remains a separate,
authorized Lojix action.

## Claude Remote Control working root

This revision consumes the CriomOS-home contract that requires every enabled
Claude Remote Control owner to declare an explicit, absolute working root
outside its home directory. CriomOS supplies the approved `/home/li/primary`
root only for li's concrete Home projection; it does not infer a root for any
other Horizon user. Before a later authorized activation, materialize the
target's user projection and stop if another local enabled owner lacks its own
explicit trusted root.

## Materialized Home deployment output

Home user-environment deployments must use CriomOS's materialized
`homeConfigurations.<user>.activationPackage` output.  It carries the
Consumer's concrete user policy, including li's approved Claude Remote Control
working root; do not substitute a standalone CriomOS-home configuration.

## Immutable source chain

- [Lojix 0.19.0](https://github.com/LiGoldragon/lojix/tree/0105f8d8f18dd91291e0a0fbe828e84ceda65714)
  is producer revision `0105f8d8f18dd91291e0a0fbe828e84ceda65714`.
- [CriomOS main](https://github.com/LiGoldragon/CriomOS/tree/02ac43b193efd7ee542ab1a4d0594c76292edc53)
  is consumer revision `02ac43b193efd7ee542ab1a4d0594c76292edc53`; its
  `flake.lock` pins that producer.
- The required predecessor crossing is [Lojix
  0.18.0](https://github.com/LiGoldragon/lojix/tree/edbb53aab003a071ffbb0f6643e8d29c0bf9b691)
  at `edbb53aab003a071ffbb0f6643e8d29c0bf9b691`, consumed by [CriomOS
  `a4322cd`](https://github.com/LiGoldragon/CriomOS/tree/a4322cd144821119936283339b1bc5926b97a738).

Use only pushed immutable revisions. The deployment proposal, target
transport, builder, selector, backend, and caller authority come from the
configured deployment interface; they are not inferred from a host, cluster,
or user name.

## Typed Lojix stages

Use the owner-only typed `meta-lojix Deploy.Host` interface and observe with
ordinary `lojix`; admission is not completion. The exact positional request
is defined by the [Lojix contract](https://github.com/LiGoldragon/Curriculum/blob/main/skills/lojix.md).

| Host action | Meaning | Durable effect |
| --- | --- | --- |
| `Evaluate` | Evaluate the selected output. | No copy or activation. |
| `Realize` | Realize the selected closure. | No copy or activation. |
| `SetBootProfile` | Copy, set the system profile, and run `boot`. | Persistent boot profile; 0.19 clears EFI default and one-shot overrides. |
| `ActivateNow` | Copy, set the system profile, and run `switch`. | Live/profile convergence; 0.19 clears EFI default and one-shot overrides. |
| `TestActivation` | Copy and run `test` without setting the system profile. | A live test effect; never use for a self-hosted controller crossing. |
| `ScheduleBootOnce` | Use the target-owned transient boot-once path. | `loader.conf` supplies the actual candidate entry; the current entry remains the persistent fallback and the candidate is one-shot. |

User-environment actions (`Realize`, `SetProfile`, `ActivateNow`) are a
separate typed surface and do not establish host-system convergence. For every
accepted request, query by deployment or event log until a terminal
`Succeeded`, `Rejected`, or `Failed` record exists.

## 0.17.5 to 0.18.0 startup crossing

This crossing is part of the controller upgrade path. The writer changed from
ten positional fields to nine: `effect_timeout_seconds` was removed, and
production remains `NoTestDefaults`. The candidate system must run its new
writer before starting its daemon; do not reuse an old startup archive. The
existing Lojix store schema is compatible for this crossing, but a schema
mismatch is a stop condition, not a reset invitation.

For a self-hosted controller, use one owner `Deploy.Host` `ActivateNow` under
the old daemon's PID-1-owned transient unit. `TestActivation` is unsafe here:
it runs a foreground test, can stop the old daemon cgroup, and has no detached
self-switch recovery or durable terminal adoption.

## 0.18.0 to 0.19.0 boot-authority crossing

Lojix 0.19 makes generated `loader.conf` the sole persistent boot authority.
Normal `SetBootProfile` and `ActivateNow` clear both EFI default and one-shot
overrides. `ScheduleBootOnce` and bootstrap preserve the actual current entry
as the persistent fallback and obtain the candidate from generated
`loader.conf`; they do not derive an entry from a generation number.

Cross the self-hosted controller as follows:

1. Read-only preflight: verify the exact immutable producer and consumer
   revisions, the configured proposal and transport, the typed selector and
   backend, store compatibility, daemon health, and absence of unrelated
   nonterminal work. Evaluate and realize the exact source before activation.
   Stop on any mismatch or missing authority.
2. Submit the first `ActivateNow` for that same immutable source through the
   old 0.18 supervisor. It must be a self-targeted host action so its
   PID-1-owned transient survives the daemon restart. Do not use
   `TestActivation`, `ScheduleBootOnce`, a script, or a manual boot command.
3. The practiced bridge may live-switch the target to 0.19 and then
   terminally fail only at the old supervisor's legacy guard for its
   synthesized `nixos-generation-N.conf`. Stop immediately. Do not retry or
   infer success from the new daemon being alive.
4. Verify the exact partial state independently: (a) the durable Lojix
   deployment and terminal failure stage/reason, (b) the realized closure and
   persistent system profile, (c) `/run/current-system` and the active 0.19
   daemon/startup archive, and (d) `loader.conf`, the actual hash-named BLS
   entry, EFI default, and EFI one-shot state. Preserve the transient journal.
   The bridge is eligible for continuation only when 0.19 is healthy and the
   failure is exactly that legacy synthesized-entry guard. Any other failure,
   mismatch, or unknown state stops the crossing.
5. Only after that exact gate, submit one new `ActivateNow` through the healthy
   0.19 supervisor, reusing the same immutable source. Observe it to terminal
   success. The 0.19 activation clears EFI default and one-shot overrides so
   `loader.conf` is again the sole authority; no reboot is implied.

Completion requires independent postconditions:

- Live: the active daemon is 0.19 and `/run/current-system` resolves to the
  exact selected closure.
- Profile: the persistent system profile resolves to that same closure.
- Boot: the selected hash-named entry is the `loader.conf` default, exists in
  the BLS directory, and both EFI default and one-shot overrides are clear.
- Ledger: the second deployment has a terminal success/`Current` record; the
  first bridge record remains retained as failed evidence.

These are separate witnesses. A healthy process, profile, or boot listing does
not establish the Lojix ledger result. No rollback, retry, reset, garbage
collection, reboot, or emergency runtime mutation is inferred after a partial
activation; obtain the required authority first.

## Practice corrections

- The earlier long closure copy exhausted the old effect timeout and was
  reported as `BuilderUnreachable`. Treat a copy failure as a terminal stage:
  inspect exact target closure validity and transport evidence, and never
  assume incomplete transfer residue is reusable.
- A self-host `TestActivation` can kill the supervisor's foreground cgroup
  without a recoverable terminal record. It may also have applied part of the
  candidate's live effect while leaving the persistent profile and boot
  selection unchanged. Stop; preserve its journal; then inspect the Lojix
  record, `/run/current-system`, the persistent profile, affected units, and
  systemd-boot's `loader.conf`/EFI default/one-shot state separately. Do not
  retry `test`, manually activate a subset, reset state, or apply a runtime
  hot fix. The self crossing is `ActivateNow` in a PID-1-owned transient unit.
- A ClaviFaber producer/consumer request-shape mismatch failed after a live
  switch. Verify the immutable producer pins and decoder shape in the complete
  closure before activation; after any activation failure, inspect live,
  profile, boot, and ledger state separately.
- BLS entries are hash-named and discovered from generated `loader.conf`.
  Never synthesize or search for `nixos-generation-N.conf` during the 0.19
  procedure.

## Repository facts

- [CriomOS deployment ownership](AGENTS.md)
- [CriomOS convergence invariants](ARCHITECTURE.md#deployment-convergence-witnesses)
- [CriomOS 0.19 pin](flake.lock)
- [Lojix 0.19 boot contract](https://github.com/LiGoldragon/lojix/blob/0105f8d8f18dd91291e0a0fbe828e84ceda65714/src/schema_runtime.rs)
- [Lojix 0.18 bridge implementation](https://github.com/LiGoldragon/lojix/blob/edbb53aab003a071ffbb0f6643e8d29c0bf9b691/src/schema_runtime.rs)
