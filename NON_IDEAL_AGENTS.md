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

The remaining root-mediated sequence is deliberately split into
non-activating gates:

1. Check Zeus free space and its trusted cache/signing-key configuration.
2. Copy the exact rooted closure to the explicit root Zeus store URI with
   `nix copy --substitute-on-destination --to "$ZEUS_NIX_STORE_URI" "$SYSTEM_CLOSURE"`.
3. Over the explicit root SSH destination, verify that exact closure is valid,
   compare it with `/run/current-system` using `nix store diff-closures`, and
   run `"$SYSTEM_CLOSURE/bin/switch-to-configuration" dry-activate`.
4. Review every removal/restart warning for effects on Bird's graphical and
   VS Codium session. Any failure, ambiguity, or active-session risk is a stop
   condition.
5. Only with separate operator approval and no active Bird session, stage the
   exact closure for the next ordinary boot by setting
   `/nix/var/nix/profiles/system` to it and running
   `"$SYSTEM_CLOSURE/bin/switch-to-configuration" boot`. Do not reboot as part
   of this workaround unless that separate action is explicitly authorized.

Never run `switch` or `test` beneath an active Bird session. Never hand-edit
VS Codium's extension registry or other lifecycle-managed JSON to force a
version: the declarative Home lifecycle owns those files and must perform any
surgical merge required to keep them user-writable.

The proper fix is declarative, protocol-aligned ownership of the Lojix daemon
and client at one revision, enabled explicitly by CriomOS, followed by typed
deployments whose terminal result truthfully records evaluation, realization,
copy, and activation. Remove this workaround when that path is proven.
