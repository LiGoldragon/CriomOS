## Shared-input pin discipline

When bumping a component pin (lojix, orchestrate, spirit, or any shared input)
in either CriomOS or CriomOS-home, check the other flake's pin for the same
input and bump it to match. The authoritative version is whichever flake was
intentionally updated; the other must follow within the same commit sequence.

When CriomOS-home is consumed as a module, CriomOS's follows overrides
deduplicate shared inputs. This discipline applies to standalone CriomOS-home
evaluations (home-manager switch without a system rebuild).

## Temporary Zeus full-system recovery path

This is a narrow recovery workaround, not standing deployment policy. The
Lojix daemon and client on Ouranos have been observed at different protocol
versions, and CriomOS does not yet enable and own the production Lojix daemon
declaratively. Until both facts are corrected, a normal daemon submission is
unsafe: do not contact the daemon for a Zeus deployment.

Use an exact pushed CriomOS revision and the canonical regular-file
`goldragon/datom.dotos`. Materialize `goldragon` / `zeus` as `CompleteHost`
through the exact-revision `lojix-bootstrap` `BuildOnly` `Horizon` request,
with the proposal's sibling encrypted-secrets directory supplied explicitly.
`BuildOnly` is the required first phase because its type has no transport or
activation field. Give it a private caller-owned journal directory, a new
durable GC-root path, a new terminal-evidence path, the
`nixosConfigurations.target.config.system.build.toplevel` selector, and the
`x86_64-linux` system. Retain its finalized journal, terminal evidence, and GC
root as the audit record.

All Nix evaluation and realization for this path must be remote-only on
Prometheus, including evaluation because CriomOS uses import-from-derivation.
Use both of these controls on every outer/manual `nix eval`, `nix build`, or
`nix run`:

```text
--option max-jobs 0 --builders '@/etc/nix/machines'
```

Before use, verify `/etc/nix/machines` contains only the intended Prometheus
builder. In addition, launch `lojix-bootstrap` with inherited `NIX_CONFIG`
setting `max-jobs = 0`, `builders = @/etc/nix/machines`, and `fallback = false`,
because its materialized-flake evaluation is a child Nix process while its
typed `NixBuilder` field constrains only realization. Supply the same
`@/etc/nix/machines` value in that typed field. A missing or non-Prometheus
builder is a stop condition, never permission to fall back locally.

From the retained generated inputs, independently evaluate the Zeus system
selector and Bird Home activation selector and the relevant system/Home
equivalence checks under the same Prometheus-only controls. The independently
realized system closure must equal the closure recorded by the bootstrap GC
root. Verify the closure and its provenance before transfer.

The remaining root-mediated sequence is deliberately split into explicit
gates. Keep `SYSTEM_CLOSURE` bound to the one independently verified closure
throughout; never substitute a freshly evaluated or similarly named path part
way through the sequence:

1. Check Zeus free space and its trusted cache/signing-key configuration.
2. Copy the exact rooted closure to the explicit root Zeus store URI with
   `nix copy --substitute-on-destination --to "$ZEUS_NIX_STORE_URI" "$SYSTEM_CLOSURE"`.
3. Over the explicit root SSH destination, verify that exact closure is valid
   and compare it with `/run/current-system` using `nix store diff-closures`.
4. Run the exact closure's `switch-to-configuration check` once, then its
   `dry-activate` once. Review every removal and restart for effects on Bird's
   graphical and VS Codium session. Any unexplained effect is a stop condition.
5. Before any live switch, set `/nix/var/nix/profiles/system` to the exact
   closure. With separate operator approval, run that closure's
   `switch-to-configuration switch` exactly once. Record the complete output.
   A nonzero result can still be a partial activation: inspect
   `/run/current-system`, the profile, affected unit results, and the preserved
   user session before deciding what happened. Never blindly retry `switch` or
   manually repeat only the failing Home activation step.
6. Preserve an active Bird session deliberately: record its sessions plus the
   niri and Codium process trees before switching, and verify them afterward.
   Never kill, signal, restart, or launch Codium or niri as part of recovery.
7. Run the same exact closure's `switch-to-configuration boot` once so the
   durable boot generation matches the live/profile closure. Verify both the
   entry selected by `/boot/loader/loader.conf` and systemd-boot's persistent
   EFI default. A stale EFI `LoaderEntryDefault` overrides `loader.conf`; with
   separate operator approval, point it at the newly installed exact generation
   and reverify that there is no conflicting one-shot entry. Do not reboot as
   part of this workaround unless that separate action is explicitly
   authorized.

Never hand-edit VS Codium's extension registry or other lifecycle-managed JSON
to force a version, and never repeat the lifecycle command ad hoc beneath the
running editor. Home owns the immutable extension declarations while the
managed Codium launcher owns the user-writable reconciliation: on Bird's next
natural Codium launch, it takes the lifecycle lock, reconciles the mutable
links, roots, and manifest in bounded passes, and atomically rewrites the
managed Claude and OpenAI registry records before launching. It fails closed
if that state cannot be made ready. A pre-activation Codium process may
therefore continue using stale mutable registry metadata until Bird closes it
normally and launches it again through the managed command.

The proper fix remains declarative, protocol-aligned ownership of the Lojix
daemon and client at one revision, enabled explicitly by CriomOS, followed by
normal typed Lojix deployments whose terminal result truthfully records
evaluation, realization, copy, and activation. Remove this workaround when
that path is proven.
