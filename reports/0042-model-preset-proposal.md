# Proposal: bounded model presets

Status: proposal only on `proposal/5f4fea-model-presets`; this report does not
activate a model, fetch a weight, change a host assignment, or deploy a system.
The external `criomos-lib/data/largeAI/llm.json` remains authoritative unless
its owner explicitly adds `enableProposalModels = true`. The module defaults
that switch to false, and disabled entries are filtered even when the switch is
turned on.

## Catalog

Prometheus may serve the two entries with verified immutable sources:

* Laguna S 2.1 UD-Q4_K_M, revision
  `750f92f90cf54159c4d7a610cb7b3e74498e75c6`, from three Unsloth shards:
  `00001` 3,683,648 bytes,
  `00002` 49,930,584,576 bytes, and
  `00003` 23,184,915,328 bytes. The module records each Hub SHA-256 SRI.
  The combined declared size is 73,119,183,552 bytes (68.11 GiB).
* Qwen3.8 27B Q8_0, revision
  `0669b98607d47046c7c2b3f801011d54a08cfccf`, file
  `Qwen3.8-27B-Q8_0.gguf`, 28,595,763,552 bytes (26.63 GiB), with its
  Hub SHA-256 SRI.

Ouranos' Laguna XS IQ4 and Laguna XS Q8 entries remain disabled because their
requested immutable source and hash were not verified. Motif 2 remains disabled
pending a verified GGUF. Motif 3 is a comment-only living choice pending
llama.cpp/source decisions. The proposal records Laguna's OpenMDW-1.1 license
as pending living confirmation. Zeus serves no model in this catalog and is
only a LAN client role; there is no node-name conditional in the module.

## Resource gate

The existing router settings remain `modelsMax = 1`, `parallel = 1`,
`MemoryHigh = 100G`, and `MemoryMax = 110G`. The declared file sizes are not a
runtime safety proof: loader allocations, context/KV cache, runtime buffers,
OS reservations, and any transient multi-residency must be measured before an
enablement decision. No arithmetic here claims that either model fits safely,
and no 90 GiB prefetch was attempted. A future enablement must provide the
loader/KV headroom measurement against both systemd limits.

## Validation boundary

`nix-instantiate --parse modules/nixos/llm.nix` passes. A narrow direct module
evaluation with a temporary fixture `criomos-lib` JSON, `largeAi = true`, and
`enableProposalModels = true` also passes: it materializes the service attrset
and reports `MemoryMax = "110G"` without building weights. The repository-wide
`nix flake check --no-build --impure` remains blocked by its documented
materialization requirement: `CriomOS: no system input was provided`. Weight
builds and service activation were not attempted. The change is a reviewable
catalog proposal only.
