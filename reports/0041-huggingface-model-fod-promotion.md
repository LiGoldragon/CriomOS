# Hugging Face model FOD promotion

## Scope

Research note for adding already-downloaded Hugging Face model weights to the
Nix store so later CriomOS builds do not download them again.

Current CriomOS shape:

- `modules/nixos/llm.nix` reads `CriomOS-lib/data/largeAI/llm.json`.
- Each model source is either one `fetchurl` file or a set of `fetchurl`
  shards linked into a per-model directory.
- The large files are Hugging Face `resolve/<commit>/<path>` URLs with SRI
  SHA-256 hashes.

The question is whether an existing tool can promote files downloaded by
Hugging Face's `hf` CLI into the Nix store/cache and emit the fixed-output
derivation metadata.

## Findings

### Nix already has the preload primitive

For a single-file `pkgs.fetchurl` fixed-output derivation, the store output is
keyed by:

```text
hash algorithm + flat file hash + output name
```

The documented primitive is:

```text
nix-store --add-fixed sha256 <file>
```

Nix's manual says `--add-fixed` registers the path using the chosen hashing
algorithm and produces the same output path as a fixed-output derivation. For
normal model files this is the right mode: flat SHA-256 over the file bytes.
Use `--recursive` only for directory outputs / unpacked snapshots.

Two adjacent commands are useful but less central:

- `nix hash file --sri <file>` computes the SRI hash CriomOS already stores.
- `nix store add-file --name <name> <file>` matched `fetchurl` in my Nix 2.34.6
  probe, but `nix-store --add-fixed` is the older command whose manual
  explicitly promises fixed-output-derivation path equivalence.

`nix-prefetch-url` and `nix store prefetch-file` solve the network prefetch
case. They download from a URL, hash the result, and put it in the store. They
do not solve the HF-cache import UX by themselves, but they are prior art for
avoiding the second download.

### Hugging Face gives enough metadata

The `hf` CLI is the supported terminal surface for Hub downloads. Relevant
features:

- `hf download <repo> [files...]`
- `--revision` for a branch/tag/commit
- `--include` / `--exclude` for subsets
- `--cache-dir` and `--local-dir`
- `--dry-run`
- `--format json`
- `--token` for private/gated repositories

The default `hf` cache is content-addressed enough to discover files already on
disk. Hugging Face documents a repo cache layout with `refs`, `blobs`, and
`snapshots`; snapshot files are symlinks to blob files. Blob names are hashes.
For LFS files, the blob identity is the LFS SHA-256 object id; for ordinary Git
files it is a Git object id, so a Nix SHA-256 still has to be computed.

The Python API is better than scraping the cache layout. `HfApi.model_info(...,
files_metadata=True)` returns the resolved repo SHA and `RepoSibling` entries
with file size, blob id, and LFS metadata when present.

### Existing prior art is close but personal

The closest match I found is Doug Campos / qmx's January 2026 write-up,
"Nixifying Local LLMs: Promoting GGUF Models to Nix Derivations." It uses a
model catalog with promoted `ggufs`, emits `fetchurl` entries for single and
split GGUF files, switches llama.cpp from `-hf` runtime downloads to `-m`
store paths, and copies promoted outputs to a private Nix cache.

That is the same high-level workflow CriomOS needs.

Limits for our use:

- It is personal dotfiles tooling, not a reusable HF-cache importer.
- The script pattern-matches a local model directory naming convention rather
  than using Hugging Face cache metadata.
- It does not encode CriomOS-lib's JSON shape.
- It appears to use `nix store add-file`; for CriomOS I would use
  `nix-store --add-fixed` for the documented FOD guarantee.

General Nix tools such as `nurl`, `nix-init`, `nix-prefetch-url`, and
`nix store prefetch-file` generate or prefetch fetchers, but I did not find a
polished tool that starts from an existing `hf` cache entry and emits a
multi-shard Hugging Face model catalog plus preloaded Nix FODs.

## Local proof

I tested with the CriomOS GitHub archive at the current remote `main` commit.
The exact store paths and test hash are intentionally not recorded here.

Probe shape:

```text
download archive to a temp file
compute SRI SHA-256 with `nix hash file --sri`
evaluate the expected `pkgs.fetchurl { url; hash; name; }` output path
add the temp file with `nix-store --add-fixed sha256`
build the same fetcher offline
build a fresh unique fetcher online to validate the hash against a real fetch
```

Results:

| Check | Result |
|---|---:|
| `nix-store --add-fixed sha256` path matched `pkgs.fetchurl` | yes |
| `nix store add-file --name` path matched `pkgs.fetchurl` on Nix 2.34.6 | yes |
| Offline `nix build --offline --no-substitute` used the preloaded path | yes |
| Fresh unique output was absent before build | yes |
| Online `nix build --refresh --no-substitute` fetched and matched the hash | yes |

I also tried to delete the preloaded test output before re-fetching that same
name. This local multi-user Nix daemon reported the path as alive, and this
user is not allowed to use `--ignore-liveness`. The fresh unique-name fetch
still validates the important part: the computed hash is accepted by the real
builder after a network fetch, and the preloaded path is accepted by an offline
build.

## Recommended design

Build a small promotion tool rather than changing the Nix module first.

Name placeholder: `hf-nix-promote`.

Primary command shape:

```text
hf-nix-promote \
  --repo unsloth/Qwen3-8B-GGUF \
  --revision <full-hf-commit> \
  --include '*.gguf' \
  --model-id qwen3-8b \
  --emit criomos-json \
  --preload
```

Pipeline:

```text
HF repo + revision + include set
  -> resolve repo metadata with Hugging Face API
  -> locate or download selected files through `hf`
  -> verify local bytes
  -> compute Nix SRI SHA-256
  -> preload each file with `nix-store --add-fixed sha256`
  -> emit CriomOS-lib model source JSON
  -> optionally `nix copy` the outputs to a binary cache
  -> run an offline Nix realization check
```

For CriomOS's current module, emit per-file entries:

```text
single GGUF file
  -> source.kind = "fetchurl"

split GGUF
  -> source.kind = "multi-shard"
  -> one fetchurl URL/hash/filename per shard
```

Use Hugging Face URLs pinned to the resolved commit:

```text
https://huggingface.co/<repo>/resolve/<commit>/<path>
```

The tool should require a full resolved commit in emitted data. Branch names
are acceptable as user input only if the tool resolves them before output.

### Why per-file FODs are better than one snapshot FOD

For GGUFs and sharded GGUFs, per-file `fetchurl` keeps the useful Nix property:
one changed shard does not invalidate every other shard. It also maps cleanly
to the existing `llm.json` and `llm.nix` model directory construction.

A recursive directory FOD using `hf download --local-dir $out` is useful only
when a consumer needs an entire repo snapshot as a directory. If we add that
mode, the builder should download into a temp cache, copy only selected files
to `$out`, remove `.cache/huggingface`, and normalize metadata before the
recursive hash is computed.

### Where `hf` belongs

Use `hf` in the promotion tool and optionally in a fallback FOD builder for
public snapshots. Do not make `hf` the default builder for single files already
expressible as `fetchurl`.

Reasons:

- `fetchurl` is smaller, older, and already fits Nix's FOD model.
- `nix-store --add-fixed` preloads exactly the same path.
- `hf` brings Python, cache metadata, Xet cache behavior, and token handling.
- `hf --local-dir` writes metadata that must be scrubbed for recursive FODs.

For gated/private Hugging Face models, prefer manual authorized download plus
promotion into a private Nix cache. Passing tokens into builders is possible in
Nix, but it is impure secret handling and should not become CriomOS's normal
model path.

## CriomOS fit

The durable data still belongs in `CriomOS-lib/data/largeAI/llm.json` because
CriomOS and CriomOS-home both consume it. The promotion tool itself should not
live in CriomOS-lib because CriomOS-lib is intentionally dependency-free.

Reasonable homes:

- a new micro-component repo if this becomes a durable ecosystem tool;
- a CriomOS `packages/` utility if it stays local to this OS surface.

The tool should not add cluster or node identity to CriomOS. It should only
emit model source records: model id, descriptor, context policy, and
commit-pinned file sources.

## Open issue for `CriomOS-6z0`

Preloading/caching solves "the build wants to download model weights again."
It does not by itself settle whether `lojix eval` should realize model FODs.

Interpolating `${modelsDir}` into a generated service script gives the script a
Nix string context that depends on the model FODs. If the eval path builds or
checks that script derivation, Nix may try to realize the model closure. With
the weights preloaded or available from a binary cache, that realization is
cheap; without them, it reaches Hugging Face.

So the model promotion tool is the right cache/population answer. If
`CriomOS-6z0` requires eval to succeed even when no model weights are present,
the LLM module may also need a laziness boundary around generated scripts or a
separate eval-only mode.

## Source notes

- Nix manual, `nix-store --add-fixed`: fixed-output path equivalence.
  <https://releases.nixos.org/nix/nix-2.13.5/manual/command-ref/nix-store.html>
- Nixpkgs manual, `fetchurl`: FOD, name/hash path behavior, SRI hashes, netrc
  caveat. <https://nixos.org/manual/nixpkgs/stable/index.html>
- `nix-prefetch-url` manpage: prefetch avoids redundant fetchurl downloads.
  <https://manpages.ubuntu.com/manpages/questing/man1/nix-prefetch-url.1.html>
- Nix manual, `nix store prefetch-file`: URL prefetch, `--name`, JSON/SRI.
  <https://nix.dev/manual/nix/2.26/command-ref/new-cli/nix3-store-prefetch-file>
- Hugging Face CLI docs: `hf download` options.
  <https://huggingface.co/docs/huggingface_hub/en/package_reference/cli>
- Hugging Face cache docs: `refs` / `blobs` / `snapshots`, cache verification.
  <https://huggingface.co/docs/huggingface_hub/v1.3.4/guides/manage-cache>
- Hugging Face API docs: `model_info(files_metadata=True)`, `RepoSibling`,
  LFS metadata. <https://huggingface.co/docs/huggingface_hub/main/package_reference/hf_api>
- qmx prior art: "Nixifying Local LLMs: Promoting GGUF Models to Nix
  Derivations." <https://random.qmx.me/posts/2026/01/08/nixifying-local-llms/>
- nurl adjacent prior art: generate Nix fetcher calls from repository URLs.
  <https://discourse.nixos.org/t/nurl-generate-nix-fetcher-calls-from-repository-urls/24374>
