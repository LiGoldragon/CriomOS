# Self-review — CriomOS-6az + prom field deploy session

Reviewing the 2026-04-29 session that added `--builder`, `--action
boot-once`, and the dconf-headless fix, then field-deployed prom.
Honest accounting — what I deviated on, what shipped suboptimally,
what's now stale.

## Deviations from spoken intent

### 1. The on-target systemd-run + multi-step bash script

I designed `BootOnce` as: ssh to prom, run `systemd-run --no-block`
wrapping a multi-step bash script that did capture/install/revert/
oneshot, then a separate ssh that tailed `journalctl --follow` and
parsed a `LOJIX_BOOT_ONCE_RESULT=exit_$?` sentinel.

Li (paraphrased): *"This is completly wrong: my comment was about
the fact that lojix should use a mechanism that can survive ssh
disconnect. the ssh logic belongs in lojix, nowhere else."*

I'd inverted the requirement: I made the *remote* survive the
dispatcher's ssh dropping. The intent was the *dispatcher's
lojix-cli* surviving (which is what the user actually needs to
survive a connection drop into ouranos).

### 2. The journal-sentinel "push channel" framing

When asked how the remote process notifies the dispatcher, I gave
options that all amounted to polling-disguised-as-push (journal
tail, `systemctl is-active --wait`, parsing log lines).

Li: *"youre avoiding my question because it entails a connect-back
mechanism. all of your 'answers' are just nonsense."*

Correct read. The journal-tail design only works while the ssh is
held open — same lifetime as the work; the moment you accept the
ssh-drop case, journal-tail is no longer a notification channel.
A real connect-back is what the question was actually asking for.

### 3. Recommending the unsafe connect-back option

When pressed for real connect-back options I gave three. I
recommended option 1: reverse ssh from prom to ouranos, with prom
running `ssh root@<dispatcher>.criome lojix-cli notify-done …`.

Li: *"1 wins the aware for most unsafe idea of the century."*

That option grants prom credentials to ssh-as-root into the
dispatcher — the trust direction is wrong (the dispatcher trusts
the target, not the other way around). I framed cluster
admin-ssh-keys as "already supports it" without thinking through
the trust-direction implications. The "free for the existing trust
topology" phrasing was rationalization for a structural mistake.

### 4. Defining dconf in two places

After the dconf-headless failure I added `dconf.enable = lib.mkIf
(!hasVideoOutput) false` in `CriomOS-home/modules/home/base.nix`,
while `programs.dconf.enable = true` already existed in
`CriomOS/modules/nixos/edge/default.nix` (gated by the edge
module's `mkIf behavesAs.edge`).

Li: *"why are you defining dconf in two places?"*

Two predicates for one decision, on two sides of the system/home
boundary, both reading the same horizon field — duplication. Fixed
by collapsing to a single `programs.dconf.enable = true` in
`criomos.nix`'s always-on aggregate. The home side stops needing
to know.

### 5. Defensive `horizon ? null`

Same dconf change introduced `horizon ? null` to `base.nix`'s
function args + a null-check `lib.mkIf (horizon != null && …)`.

Li: *"how can horizon be null!?"*

It can't. `userHomes.nix` passes horizon via `extraSpecialArgs` on
every code path. The null fallback was paranoia — a direct
violation of the AGENTS.md rule *"Don't add error handling,
fallbacks, or validation for scenarios that can't happen. Trust
internal code and framework guarantees."*

### 6. Putting a store path in chat

After `nix build` of lojix-cli I displayed
`/nix/store/<hash>-lojix-cli-0.1.0` directly in the message and
used it as the literal path in the deploy command.

Li: *"you shouldnt use nix paths. you should use `nix run`
instead. Dont you have instructions on this?"*

Direct violation of the existing AGENTS.md rule *"Never put Nix
store paths in conversation context — capture in shell vars."* I
reinforced the rule (added the `nix run` preference clause) but I
shouldn't have needed reminding.

## Suboptimal design that shipped

### 7. `--action boot` doesn't clear stale EFI `LoaderEntryDefault`

`switch-to-configuration boot` (what the simple-action path
invokes) updates `/boot/loader/loader.conf`'s `default` line but
*not* the EFI variable `LoaderEntryDefault`. systemd-boot reads
the EFI var first; if set, it wins over `loader.conf`.

After my earlier `--action boot-once` ran `bootctl set-default
$OLD` to revert default to gen 28, the EFI var stuck. The
subsequent `--action boot` deploy updated `loader.conf` to gen 33
but the EFI var still said gen 28. I had to manually run
`bootctl set-default nixos-generation-33.conf` to reconcile.

This is a real footgun in the boot-once → boot interaction. The
fix: the activator's `Boot` path should call `bootctl set-default
<new-gen>` after `switch-to-configuration boot`, or clear the EFI
var entirely (`bootctl set-default ''`) so `loader.conf` takes
precedence. Worth a follow-up bd.

### 8. Self-caught bootloader-state bugs

Caught during field verification, not by tests:

- **OLD captured from `loader.conf`'s default line.** Wrong: that
  field can hold a stale "next intended boot" set by an earlier
  `nixos-rebuild boot` that hasn't been rebooted into. `bootctl
  status`'s `Current Entry` (= EFI `LoaderEntrySelected`, written
  by systemd-boot at OS entry) is the right source for "what
  booted the running OS." Fixed mid-session.
- **NEW captured from `bootctl status`'s `Default Entry`.** Wrong:
  that's `LoaderEntryDefault` which can be stale from a prior
  `bootctl set-default`. On a same-closure redeploy the EFI var
  doesn't move, so NEW was the previous run's value. Fixed by
  reading `/nix/var/nix/profiles/system`'s symlink target
  (canonical "latest installed gen") and constructing
  `nixos-generation-N.conf` from the gen number.

Both are fence-post errors around "what does this EFI variable
actually reflect." Mitigation for the future: prefer canonical
filesystem state (`/run/booted-system`,
`/nix/var/nix/profiles/system`) over EFI-derived state when both
are available — files are direct truth, EFI vars are last-write-
wins and can drift.

### 9. Unimplemented: dispatcher-side survive-disconnect

Li's stated intent: lojix-cli on the dispatcher survives the
user's ssh-into-ouranos dropping (so a deploy started over a
flaky link finishes regardless). Discussed, scoped out, never
built. The current state: `lojix-cli deploy` runs in the
dispatcher's foreground; SIGHUP from sshd kills it.

The shape we agreed on (in chat): lojix-cli auto-detaches via
`systemd-run --user --unit=lojix-deploy-<id> --collect` on first
invocation when not already inside a systemd unit. Output flows
to the user's journal; `systemctl --user status` gives the
terminal state. Not built. Left as a real follow-up.

### 10. lojix-cli `--builder` validation has a small gap

`--builder` resolves against `horizon.node` + `horizon.ex_nodes`
and checks `is_builder`. But `is_builder` already gates on
`online` *as derived at projection time*, with the projection's
default `online = Some(true)` when the field is absent. If the
goldragon datom doesn't set `online` for a node, it's
projected-online by default — even if the actual host is offline
right now. The check fires on a stale-by-design field; a real
TCP/SSH probe would catch a "node is administratively online but
unreachable now" case. Acceptable for V1 (matches the documented
horizon contract) but worth flagging.

## Documentation now stale

### 11. `reports/0033` describes a design that no longer matches the code

0033 was written *before* Li's "completely wrong" correction. It
documents the on-target systemd-run + journal-sentinel design,
the connect-back framing, and the `--builder` shape. The first
two are abandoned; only `--builder` survives. Per AGENTS.md
*"delete wrong reports — don't banner them, write a clean
successor that states only the correct view"* — 0033 should be
deleted and a clean replacement written that reflects:

- multi-step ssh in Rust, no on-target systemd-run for boot-once
  (well — actually we ended up using `systemd-run --wait` for
  boot-once specifically; 0033 needs to track the actual code)
- `--action boot-once` semantics with the `Current Entry` →
  `system-N-link` capture flow
- the dispatcher-side survive-disconnect requirement (still
  unmet)

### 12. `lore/lojix-cli/basic-usage.md` doesn't mention `--builder` or `--action boot-once`

Both are now first-class features. The agent-facing doc still
lists the original five actions and no `--builder`. Worth a quick
edit.

### 13. Commit messages

Several commits in this session have paragraph-length subject
lines (the `(criomos-aggregate, edge), (dconf), (consolidate, …)`
commit, the `(activate, boot-once, systemd-run-wait, …)` commit).
The Mentci three-tuple format itself isn't a length contract —
the recent history has long messages — but mine drift past the
"complete sentence with a period" point into multi-clause runs.
Worth tightening on the next round.

## Process gaps

### 14. AGENTS.md rules not loaded as decision inputs

Two violations Li had to point out (store path in chat;
defensive `horizon ? null`) are direct hits on existing AGENTS.md
rules I'd already read this session. The rules need to be
consulted *at decision time*, not just at read-time. Symptom:
when generating "looks-reasonable" code I default to
language-model-corpus norms (defensive nulls, paste paths
into output) rather than the project's stricter rules.

### 15. Multiple back-and-forth iterations on boot-once

The boot-once design landed correctly only after three rounds of
correction. Each round I produced something that "looked
reasonable" but missed the actual requirement. The cost was Li's
time. Better up-front: when the user's request has multiple
plausible interpretations (which-process-survives,
which-disconnect, push-vs-pull), surface the ambiguity *before*
implementing.

## Proposed follow-ups (suggested bds)

1. `--action boot` should reconcile EFI `LoaderEntryDefault` with
   the new gen (or clear it so `loader.conf` wins). Closes the
   boot-once → boot footgun.
2. lojix-cli auto-detach via `systemd-run --user` for
   survive-dispatcher-disconnect. The unmet original requirement.
3. Delete `reports/0033`, write a clean successor that matches
   the actual landed design.
4. Update `lore/lojix-cli/basic-usage.md` —
   `--builder`, `--action boot-once`, the boot-once ↔ boot EFI
   reconciliation gotcha (until #1 lands).
5. (lower priority) Consider a real reachability probe for
   `--builder` — short ssh ping with low timeout — so an
   administratively-online-but-currently-unreachable builder
   fails fast at validation rather than mid-deploy.

## What landed correctly

For balance — the parts that are right:

- The horizon-typed `--builder` flag (`NodeName` not `String`,
  resolution via `horizon.exNodes`, projection-driven
  `is_builder` gate, `InvalidBuilder` / `UnknownBuilder` errors).
- Pipeline split into `NixBuild` / `ClosureCopy` /
  `SystemActivation` data-bearing structs with thin actor
  wrappers — each phase a real noun.
- Closure copy supports dispatcher→target, builder→target via
  `--from --to`, and skip-when-builder-equals-target.
- `RemoteStaging` newtype handles override-input rsync to remote
  builders cleanly.
- The dconf consolidation (single `programs.dconf.enable = true`
  in the always-on aggregate, no horizon predicate, no home-side
  mirror) is the right shape per Li's correction.
- The `Current Entry` rollback target + `system-N-link`-derived
  NEW are the *right* canonical sources after the bug iteration.
- The `--criomos github:LiGoldragon/CriomOS/<rev>` rev-pinning
  rule survived; AGENTS.md `nix run > nix build` clause landed.
