# Native Swift path (SPEC §8) — M0 feasibility spike results

The endgame is a native Swift `Murmur.app`: SwiftUI menu bar + Hub window,
Parakeet STT on the **Neural Engine** via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML), Qwen3
cleanup on the GPU via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm),
notarized and double-clickable. The Python app's Linux-tested pure-logic
modules (`HudStateMachine`, `EndpointDetector`, `HotkeyMachine`,
`OnboardingFlow`, `HistoryStore`, the config schema) are the port spec; their
test suites are the acceptance criteria.

This document records the M0 spike: measured evidence for/against the port,
gathered with `native/` (the `murmur-bench` harness) and
`scripts/native_baseline.py` before any app code. Per CONTRIBUTING rule 4,
trust these numbers only for the machine below; rerun both harnesses to
refresh.

## Method

Identical synthetic WAVs (16 kHz mono, `say` + `afconvert`, see
`native/scripts/make-fixtures.sh`): 4.6 s / 9.6 s / 20.2 s utterances with
fillers and self-corrections. 3 runs per measurement, run sequentially (never
both stacks at once — 16 GB). Swift harness: `swift run -c release
murmur-bench`. Python harness: `uv run python scripts/native_baseline.py`,
driving the production code paths (`parakeet_mlx.from_pretrained().transcribe`,
`CleanupEngine` with prefix KV caches).

**Machine:** Apple M1, 16 GB, macOS 15.7.4. Models: `parakeet-tdt-0.6b-v3`
(both stacks; CoreML build `FluidInference/parakeet-tdt-0.6b-v3-coreml`),
`mlx-community/Qwen3-4B-4bit`.

## Result 1 — batch STT: ANE beats the GPU path 3–8× (gate: PASS)

| | Python `parakeet-mlx` (GPU) | Swift FluidAudio (ANE) | speedup |
|---|---|---|---|
| model load (warm) | 1.64 s | **0.35 s** | 4.7× |
| 4.6 s utterance | 0.31–2.70 s | **0.131–0.137 s** | ≥2.4× |
| 9.6 s utterance | 0.62–0.74 s | **0.169–0.187 s** | ~3.7× |
| 20.2 s utterance | 1.26–2.49 s | **0.25–0.30 s** | 5–8× |

Transcript quality is equivalent on these fixtures (both near-perfect on the
synthetic voice; one filler-word difference on the 9.6 s file). The Swift
numbers are inside SPEC §6's `<150 ms` stop-to-final budget for typical
dictations — a budget the Python stack misses by 5–15×, and they come off the
GPU entirely, removing the STT↔cleanup contention that `mx.clear_cache()`
works around today (see ARCHITECTURE.md).

First run downloads the CoreML models (~97 s total on this connection) and
compiles them for the ANE; subsequent loads are the 0.35 s above.

## Result 2 — streaming drafts: sliding window doesn't fit dictation; incremental re-transcription does (gate: fallback selected)

`SlidingWindowAsrManager` probed at real-time pace (0.5 s chunks), measuring
when the first **volatile** (gray draft) and **confirmed** (stable) text
appears, relative to audio position:

| config | 4.6 s | 9.6 s | 20.2 s |
|---|---|---|---|
| `.streaming` preset (11 s chunks, 10 s min-confirm) | nothing until finalize | nothing until finalize | first draft @ 13 s |
| short-form tuning (3 s chunks, 3 s min-confirm) | draft @ 4 s, never confirms | draft @ 4 s, confirms @ 7 s | draft @ 4 s, confirms @ 7 s |

Even tuned aggressively, the sliding window shows nothing for the first ~4 s
of speech — today's Python HUD shows drafts within ~2 s. **M5 therefore uses
incremental re-transcription**: re-run batch transcription over the
accumulated session audio on a ~1 s cadence and split stable/changed text
with the existing `split_stable_prefix` logic. Result 1 makes this affordable
— a full re-transcribe costs 0.13–0.27 s on the ANE, so drafts can refresh
*faster* than the current 2 s chunk cadence, with batch-quality text (the
EOU-120m streaming model and its 4.9–8.2 % WER are not needed). Finalize from
streaming mode measured 0.12–0.22 s, consistent with Result 1.

## Result 3 — cleanup LLM via mlx-swift

Python production-path targets on this machine (`scripts/native_baseline.py`,
`light` style, prefix KV cache, status `ok` on all runs): load 3.20 s, warmup
(prefix prefill + tiny gen) 6.98 s, then total cleanup per utterance
1.20–1.28 s (4.6 s fixture), 2.16–2.22 s (9.6 s), 4.41–4.73 s (20.2 s). The
Python decode rate is ~21 tok/s (ARCHITECTURE.md). Swift must match or beat
these (M6 gate).

**Swift-side status: API validated, full inference deferred to the Xcode
target.** The `murmur-bench-llm` harness compiles and links against
`mlx-swift-lm` 3.31 (Qwen3-4B-4bit via `LLMModelFactory.loadContainer` +
`MLXLMCommon.generate`, `enable_thinking: false` confirmed from the upstream
integration tests), so the cleanup API surface is real and ported-shaped. It
does **not** run from a SwiftPM CLI build: mlx-swift's Metal kernel library
(`default.metallib`) is produced by an Xcode build rule, not by
`swift build`/`swift run` (see the toolchain note below), so the binary aborts
at startup with `Failed to load the default metallib`. Hand-compiling the
generated kernels is not a viable shortcut — mlx ships a prebuilt metallib
precisely because the templated attention/GEMM kernels are large. **M6 runs
this benchmark inside M1's Xcode `Murmur.app` target, where the metallib is a
standard build phase, gated against the Python targets above.** The decision
between (a) and (b) does not hinge on this number: STT (Result 1) is the
dominant latency component and the clearest ANE win, and cleanup parity is a
within-(b) tuning question, not an (a)-vs-(b) question.

### Toolchain & packaging note (verified — shapes M4/M6/M7)

Getting mlx-swift to *run* surfaced two real requirements, neither fatal but
both load-bearing for the plan:

1. **Metal toolchain is a separate Xcode 26 component.** A fresh Xcode 26.3
   install cannot compile `.metal` shaders until
   `xcodebuild -downloadComponent MetalToolchain` is run; before that,
   `xcrun metal` reports "missing Metal Toolchain" and no `default.metallib`
   is produced. One-time, but a documented setup step for any contributor
   building the Swift app.
2. **mlx-swift's metallib is built by an Xcode build rule, not plain
   `swift build`.** Pure SwiftPM CLI builds (`swift build` / `swift run`)
   produce the binary but not the `mlx-swift_Cmlx` resource bundle, so the
   binary aborts at startup with `Failed to load the default metallib`
   (`stream.cpp:115`) — the same failure class the recon flagged for Python
   MLX bundling (janhq/jan#8046). mlx-swift ships `tools/create-xcframework.sh`
   for exactly this reason.

**Implication for the plan, and why it favors (b):** the real app (M1's
`Murmur.app`) is an **Xcode app target**, where Metal-shader compilation and
metallib bundling are a standard build phase — so the cleanup LLM (M6) builds
and ships correctly there. The CLI-only spike harness is the awkward case, not
the app. The equivalent Python-MLX problem (recon: nobody has shipped an
MLX-Python `.app`) has no such well-trodden fix. Net: a known one-time
toolchain download and an Xcode-target requirement, versus an unsolved
packaging story.

## Gate outcomes for the migration plan

| gate | outcome |
|---|---|
| M4 (engine port) STT at-or-better than Python | **PASS** — proceed as planned |
| M5 (HUD) two-tone drafts | **re-transcription strategy**, not SlidingWindow; cadence target ≤1 s |
| M6 (cleanup) latency parity | **API validated, benchmark deferred to M1's Xcode target** (CLI can't build MLX's metallib); Python targets recorded above are the gate |

## Harness usage

```sh
native/scripts/make-fixtures.sh                          # regenerate WAVs
uv run python scripts/native_baseline.py --out /tmp/python.json   # repo root

cd native
swift run -c release murmur-bench fixtures --out /tmp/swift-stt.json   # STT — runs from CLI
```

The STT harness (`murmur-bench`, FluidAudio/CoreML) runs from a plain SwiftPM
build. The cleanup harness (`murmur-bench-llm`, mlx-swift) **compiles** the
same way but cannot run from the CLI — MLX's metallib is an Xcode build-rule
artifact (toolchain note above), so its benchmark moves into M1's Xcode app
target. Both Swift harness and the Python baseline write JSON with per-run
timings and transcripts for side-by-side diffing.
