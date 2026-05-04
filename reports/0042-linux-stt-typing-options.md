# Linux STT Typing Options

Research date: 2026-05-05.

## Prior Work

The missing reports were found in the archive repo:

- [`../criomos-archive/proposals/voice-typing.md`](../criomos-archive/proposals/voice-typing.md)
- [`../criomos-archive/proposals/voice-typing-research.md`](../criomos-archive/proposals/voice-typing-research.md)

This report supersedes them for current CriomOS work. The archive copies
are historical only; the main stale parts are the app landscape and niri
text-input status. The model direction remains mostly right: fast local
draft, better server/local final pass, optional correction with a local LLM
and user glossary.

No paid STT or LLM API call was made for this refresh.

## Current Answer

For CriomOS/niri, the best practical path is:

1. **Trial now:** package and try `voxtype` from nixpkgs first. It is
   already in nixpkgs as `0.6.5`, is a Rust Wayland/X11 dictation daemon,
   supports compositor-triggered push-to-talk, and can use `whisper.cpp`
   with Vulkan. Configure output away from `wtype` on niri if the open
   wtype bugs reproduce; use `dotool`, `ydotool`, or paste fallback.
2. **Best polished off-the-shelf candidate:** package **Speed of Sound** if
   the portal route works on niri. It is MIT, actively moving, offline by
   default, supports Whisper/Parakeet/Canary via Sherpa ONNX, uses XDG
   Desktop Portals for typing, and can call self-hosted LLMs for text
   polishing.
3. **Best custom shape:** keep the archive `criome-dictate` design as the
   target if the off-the-shelf apps feel wrong. The unique missing feature
   is not raw ASR; it is safe multi-pass dictation with a preview/revision
   UX, glossary, Sanskrit/IAST normalization, and Noctalia/niri status.

## Model Shortlist

| Need | Current best candidate | Why | Constraint |
|---|---|---|---|
| Mature local multilingual typing | `whisper.cpp` + `large-v3-turbo` | Vulkan works on Linux/AMD; `whisper-cpp` is in nixpkgs at `1.8.4`; broad language support | Whisper streaming is shimmed/chunked, not native |
| Fast English local typing | NVIDIA Nemotron Speech Streaming 0.6B | New March 2026 English streaming model, cache-aware FastConformer/RNNT; NVIDIA docs position it for real-time streaming | English only; NeMo/NIM/Python path is heavier than `whisper.cpp` |
| Fast CPU English draft | Moonshine Voice / Moonshine v2 | Linux CPU timings are in the 100-300 ms class for small/medium models; built for live interfaces | English only; not in nixpkgs |
| Fast European multilingual | Parakeet-TDT 0.6B v3 | 600M, 25 European languages, punctuation/capitalization/timestamps, permissive CC BY 4.0 | NeMo/ONNX packaging work; no Sanskrit/Indic |
| Broad non-European / Hindi | Qwen3-ASR 0.6B/1.7B or Voxtral Realtime | Qwen3-ASR supports 30 languages plus 22 Chinese dialects; Voxtral Realtime covers 13 languages and low latency | Python/vLLM style deployment; no Sanskrit in either shortlist |
| Tail languages / future Sanskrit exploration | Meta Omnilingual ASR | Apache 2.0, 1600+ languages, strong low-resource research direction | Research/toolkit model, not yet a dictation UX |
| Best paid/cloud escape hatch | OpenAI `gpt-4o-transcribe`, ElevenLabs Scribe v2, Mistral Voxtral, Deepgram Flux | Strongest convenience/accuracy candidates for hard audio | Paid API permission required before any test |

## App Shortlist

| App | Fit | Notes |
|---|---|---|
| `voxtype` | Best first trial | Already in nixpkgs. Supports `whisper.cpp`, optional ONNX engines, post-process command, status JSON, compositor bindings, and type/clipboard/paste output. The upstream docs prefer `wtype`, but niri still has open `wtype` issues, so test `dotool`/`ydotool` fallback. |
| Speed of Sound | Best polished app to package | MIT, latest release seen: `v0.13.0` on 2026-04-21. Offline by default, model browser, portal typing, optional self-hosted LLM polishing. Packaging is work because it is not in nixpkgs. |
| Hyprvoice | Closest architecture to archive design | Go daemon, PipeWire, 26 STT backends, optional LLM post-processing, ydotool/wtype/clipboard injection, custom prompt/keywords. Not in nixpkgs. |
| Speech Note | Best GUI model playground | Mature offline Linux app with many STT/TTS engines and Wayland active-window insertion via `ydotool`; more note-taking/model-browser than system dictation daemon. Not in nixpkgs under an obvious attr. |
| waystt | Minimal niri-friendly tool | Rust, signal-driven, ships niri keybind examples and ydotool/wl-copy piping. Default providers are paid OpenAI/Google, so it is not the best local-first path without modification. |

## Niri Input Status

The old report said niri lacked text-input support. That specific claim is
outdated: niri issue `#2476` is closed, and the maintainer states niri
already supports the needed protocol for IME-style text input.

For synthesized typing, the practical issue is still `wtype`. The open
bugs remain relevant:

- `niri#2314`: after `wtype`, focused apps can stop receiving real
  keyboard input until refocused.
- `niri#2280`: `wtype` can produce wrong characters with some layouts.

Therefore the current conservative typing order for CriomOS is:

1. XDG Desktop Portal typing, if Speed of Sound works cleanly on niri.
2. `dotool` for non-US layouts, where the app supports it.
3. `ydotool`/`ydotoold` for compositor-independent typing.
4. Clipboard + paste as a fallback.
5. `wtype` only after a short niri-specific shakedown.

## Recommendation

The next concrete step should be a narrow local trial:

1. Add `voxtype`, `whisper-cpp`, `dotool`, `ydotool`, and `wl-clipboard`
   to the user/system surface through Nix.
2. Configure `voxtype` with `large-v3-turbo`, Vulkan enabled, compositor
   keybindings, and non-`wtype` output first.
3. Test three real utterance classes: English prose, Spanish/French
   fragments, and Sanskrit terms spoken inside English.
4. If raw ASR is acceptable but style/vocabulary is not, add a local
   post-process command against the prom-hosted local model, not a paid API.
5. If the UX still feels like a tool rather than a native typing surface,
   package Speed of Sound next and test portal typing; then decide whether
   the custom `criome-dictate` path is justified.

The durable conclusion is that "best STT" is now a stack choice, not one
model. `whisper.cpp` remains the reproducible Linux backbone. Nemotron,
Moonshine, Parakeet, Qwen3-ASR, and Voxtral are the current frontier
pieces to selectively integrate once their Linux/Nix packaging path is
clean.

## Sources Checked

- OpenAI speech-to-text docs: `gpt-4o-transcribe`,
  `gpt-4o-mini-transcribe`, and diarization support:
  <https://developers.openai.com/api/docs/guides/speech-to-text>
- OpenAI next-generation audio model note:
  <https://openai.com/index/introducing-our-next-generation-audio-models/>
- Mistral Voxtral Transcribe 2:
  <https://mistral.ai/news/voxtral-transcribe-2>
- Mistral Voxtral Mini Transcribe 2 model card:
  <https://docs.mistral.ai/models/model-cards/voxtral-mini-transcribe-26-02>
- NVIDIA Parakeet-TDT 0.6B v3:
  <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
- NVIDIA Nemotron Speech Streaming 0.6B:
  <https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b>
- NVIDIA ASR NIM Nemotron streaming docs:
  <https://docs.nvidia.com/nim/speech/latest/asr/deploy-asr-models/nemotron-asr-streaming.html>
- NVIDIA NeMo model chooser:
  <https://docs.nvidia.com/nemo/speech/nightly/starthere/choosing_a_model.html>
- Moonshine Voice / Linux benchmarks:
  <https://github.com/moonshine-ai/moonshine>
- Moonshine v2 paper:
  <https://arxiv.org/abs/2602.12241>
- Kyutai STT:
  <https://kyutai.org/stt>
- Qwen3-ASR:
  <https://github.com/QwenLM/Qwen3-ASR>
- Qwen3-ASR technical report:
  <https://arxiv.org/abs/2601.21337>
- Meta Omnilingual ASR:
  <https://github.com/facebookresearch/omnilingual-asr>
- Omnilingual ASR paper:
  <https://arxiv.org/abs/2511.09690>
- Compact on-device streaming ASR / Nemotron ONNX quantization paper:
  <https://arxiv.org/abs/2604.14493>
- `whisper.cpp`:
  <https://github.com/ggml-org/whisper.cpp>
- Speed of Sound:
  <https://github.com/zugaldia/speedofsound>
- Speed of Sound FAQ:
  <https://www.speedofsound.io/faq/>
- Flathub Speed of Sound summary:
  <https://flathub.org/en/apps/io.speedofsound.SpeedOfSound>
- Voxtype:
  <https://github.com/peteonrails/voxtype>
- Voxtype Parakeet notes:
  <https://voxtype.io/docs/PARAKEET>
- Hyprvoice:
  <https://github.com/LeonardoTrapani/hyprvoice>
- waystt:
  <https://github.com/sevos/waystt>
- Speech Note:
  <https://github.com/mkiol/dsnote>
- niri `wtype` issue:
  <https://github.com/niri-wm/niri/issues/2314>
- niri text-input issue:
  <https://github.com/niri-wm/niri/issues/2476>
