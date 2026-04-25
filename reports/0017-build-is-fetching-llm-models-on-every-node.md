# The overnight build was downloading LLM models on ouranos

## Finding

`pgrep -P` on the long-running nixbld worker (PID 2173855, ~11 hours
elapsed) showed the actual command:

```
curl --location ... --continue-at -
  https://huggingface.co/unsloth/GLM-4.7-Flash-GGUF/resolve/0d32489e.../GLM-4.7-Flash-Q4_K_M.gguf
  --output /nix/store/8j5dvjk2fbj7bhja5j7l0pczqhfwskyq-GLM-4.7-Flash-Q4_K_M.gguf
```

Average download bandwidth ~800 KiB/s. A `Q4_K_M` quantization of a
"Flash" model is multi-GB. The build is **ouranos** (a laptop), not
prometheus (the LargeAiRouter that actually serves LLMs).

## Root cause — llm.nix is completely ungated

[modules/nixos/llm.nix](../modules/nixos/llm.nix) has **no `mkIf`**.
Every node that imports it gets:

1. `modelsDir` — a `runCommand` derivation that fetches **every** model
   listed in `data/config/largeAI/llm.json` and links them into a
   models directory
2. The full `${nodeName}-llama-router` systemd service
3. The `llama` system user + group

`criomos.nix` imports `./llm.nix` unconditionally, so every node — not
just prometheus — pulls all models. balboa (rock64), klio (now decom),
ouranos (T14 laptop), tiger (E15 laptop), zeus (T14 laptop) all end up
with the full model set.

## Why this isn't visible at eval time

Nix flake-eval only computes derivation hashes; it does NOT realise
the models. `lojix eval` is green for all 5 nodes because eval
succeeds — the FOD fetches happen only at `lojix build` (or anything
that triggers realisation). That's why this only surfaced when the
overnight build started actually pulling things.

## Fix

Wrap [llm.nix](../modules/nixos/llm.nix) in `mkIf behavesAs.largeAi`
(or `mkIf behavesAs.center && size.atLeastLarge`, depending on whether
"can serve LLMs" is the right semantic).

`behavesAs.largeAi` is true for `LargeAi` + `LargeAiRouter` species
(per [horizon-rs/lib/src/node.rs](../repos/horizon-rs/lib/src/node.rs)
`BehavesAs::derive`). In current goldragon, only prometheus matches.
The other 5 nodes drop the entire llm.nix block including all model
fetches.

Patch shape:

```nix
{ lib, pkgs, config, horizon, ... }:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;
  …
in
mkIf behavesAs.largeAi {
  users.users.llama = { … };
  users.groups.llama = {};
  networking.firewall.allowedTCPPorts = [ serverPort ];
  systemd.tmpfiles.rules = [ … ];
  systemd.services.${serviceName} = { … };
}
```

## Why this kills the bloat audit's residual concern

The 0013 closure-bloat audit estimated ~1.5–2.5 GB recoverable per
node. That estimate did NOT include LLM models because the audit
agents read the .nix files but didn't realise the FOD targets. The
real per-node savings on the 4 non-router nodes is **multi-GB to tens
of GB**, dwarfing every other gate we've discussed.

## Recommendation

1. **Kill the in-flight build.** It's ~11h into a download for a model
   ouranos shouldn't have. Wasted bandwidth at this point.
2. **Gate `llm.nix`** with `mkIf behavesAs.largeAi`. Push.
3. **`lojix eval` regression** for all 5 nodes — drv hashes for
   ouranos / tiger / zeus / balboa change (drop llm.nix); prometheus
   drv unchanged.
4. **Restart `lojix build` on ouranos**. Should now finish in
   minutes, not hours, because all the heavy FODs are gone for that
   node.
5. **Audit other potentially-ungated heavy modules** in the same
   pass — anything else with FOD fetches that fires unconditionally?
   `complex.nix` (clavifaber via callPackage — small), `network/*`
   (no FOD), `metal/default.nix` (firmware blobs are small + already
   bundled).

## Open question

Does prometheus's llm config also pull models the operator no longer
wants? Worth a quick read of `data/config/largeAI/llm.json` after the
gate fix lands — if the model list is also bloated (e.g. multiple Flash
models the cluster doesn't actually serve), prune it.
