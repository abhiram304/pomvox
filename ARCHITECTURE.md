# Murmur architecture

This documents the system **as implemented**. [SPEC.md](SPEC.md) is the
product spec and phased roadmap; when they disagree about the future, SPEC
wins — when they disagree about the present, this file wins.

Guiding constraints, in priority order:

1. **Local-only.** Audio and text never leave the machine. The only network
   operation is the one-time model download from Hugging Face.
2. **Latency is a feature.** Hotkey-release → inserted text is a real-time
   budget, instrumented per stage on every utterance.
3. **Degrade gracefully.** Any failure in a quality stage (cleanup) falls back
   to the previous stage's output. Text may arrive uncleaned; it must never
   arrive late-forever or not at all.
4. **Open-source first.** Anything model-shaped is a config value
   (`~/.murmur/config.toml`), not a constant. Users swap STT and cleanup
   models to trade speed for quality on their hardware.

## Pipeline

```
[Fn held / Fn+Space]                                  hotkey.py (CGEventTap)
   │
   ▼
[Mic capture] ──16 kHz mono PCM blocks──► [queue]     audio.py (sounddevice)
   │                                         │
   ▼                                         ▼
[release / Esc]                    [STT worker thread]        stt.py
                                     parakeet-mlx transcribe_stream,
                                     fed ~2 s chunks while recording
                                             │  final transcript
                                             ▼
                                   [LLM cleanup]              cleanup.py
                                     mlx-lm (Qwen3-4B-4bit), polish/light,
                                     deadline + guards, raw-text fallback
                                             │  cleaned (or raw) text
                                             ▼
                                   [Insertion]                insert.py
                                     NSPasteboard + synthesized ⌘V
```

The menu bar (`menubar.py`, rumps) mirrors state (🎤 idle · 🔴 recording ·
✍️ transcribing) and owns runtime toggles (cleanup on/off, style). `bench.py`
stamps per-stage timings and logs one summary line per utterance.

## Threading model

Four threads, one owner per resource (see `app.py` docstring):

| thread | owns | notes |
|---|---|---|
| main | rumps run loop + CGEventTap | tap must be installed before `run()` |
| audio callback | sounddevice stream | pushes PCM blocks onto a queue |
| STT worker | Parakeet model **and** the cleanup pass | single consumer of the queue |
| cleanup loader | loads + warms the mlx-lm model at startup, then exits | failure disables cleanup, app stays usable |

Cleanup runs synchronously **on the STT worker** after the transcript
finalizes: utterances therefore insert in order, and the worst case is bounded
by the cleanup deadline. `HotkeyMachine` (pure, unit-tested) holds the
authoritative `IDLE → RECORDING(ptt|toggle) → TRANSCRIBING → IDLE` state; the
controller reacts to its decisions.

## STT stage (`stt.py`)

`transcribe_stream` is fed ~2 s aggregated chunks (`Chunker`) *while
recording*, because each `add_audio()` call costs a fixed ~0.5–0.8 s on the
GPU regardless of chunk size — feeding raw 100 ms blocks runs slower than
realtime, and 2 s chunks run ~3× faster. On stop, only the buffered tail
remains to process, so stop-to-transcript is roughly one `add_audio` call
(~0.8 s) plus decode. This fixed per-call cost is the current latency floor of
the STT stage; reducing it means changes upstream in parakeet-mlx, not here.

## Cleanup stage (`cleanup.py`)

Split in two, mirroring `stt.Transcriber`:

- **Pure logic at module level** — unit-testable on any platform:
  `build_messages` (system rules + few-shot examples, `light`/`polish`
  styles), `accept_output` (sanity guards: empty, `<think>` leakage, role
  prefixes, length ratios), `run_cleanup` (fallback wrapper returning
  `(text, status)`).
- **`CleanupEngine`** — owns the mlx-lm model behind deferred imports.

Design rule: **never block, never trust.** Every failure path — deadline hit,
exception, model not loaded yet, suspicious output — returns the raw
transcript. Statuses (`ok | timeout | rejected | error`) are logged per
utterance.

Performance techniques, each measured on-device before landing:

- **Prefix KV cache.** ~95% of the prompt (system + few-shot examples) never
  changes, so its KV cache is prefilled once per style at warmup and
  deep-copied per call; only the user's words are prefilled per utterance.
  Cut per-utterance cleanup from ~2.0–3.8 s to ~0.6–2.6 s. The prefix is
  derived empirically (longest common token prefix of two renders) because
  Qwen3's chat template renders the final assistant turn differently from
  earlier ones.
- **Buffer-pool clear.** `mx.clear_cache()` before generation: the STT pass
  that just ran leaves the MLX buffer pool full of Parakeet-shaped buffers,
  which taxes the first generation (~0.5 s measured standalone).
- **Thinking disabled.** Qwen3 is a hybrid-thinking model;
  `enable_thinking=False` is required to hold the latency budget, with the
  `<think>` guard in `accept_output` as backstop.

## Latency budget (measured, M1 16 GB)

```
stage          typical        scales with
─────────────  ─────────────  ──────────────────────────────
stt_finalize   0.8–2.1 s      utterance length (tail drain)
cleanup        1.2–2.5 s      OUTPUT length: ~0.5 s prefill
                              + decode at ~21 tok/s
insert         1–10 ms        —
─────────────  ─────────────  ──────────────────────────────
total          2.0–4.0 s
```

Cleanup is decode-bound: the only remaining levers are a smaller model
(measured: Qwen3-1.7B fails self-corrections — see git history), speculative
decoding (unexplored), or shorter outputs. Per-utterance log lines
(`bench:` and `cleanup: gen`) carry the live numbers; trust them over this
table.

## Configuration (`config.py`)

`~/.murmur/config.toml`, every key optional, malformed sections fall back to
defaults with a logged warning — never crash on config. Model ids, hotkeys,
cleanup style/deadline, insertion method are all config values
(see [config.example.toml](config.example.toml)). Menu-bar toggles override
config at runtime without persisting.

## Stubs (planned phases)

`vad.py` (auto-stop endpointing), `hud.py` (live draft overlay),
`context.py` (per-app tone profiles), `dictionary.py` (custom words) are
docstring-only placeholders for SPEC Phases 2/4 — the seams exist so the
pipeline shape doesn't change when they land.
