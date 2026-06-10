# Murmur — Product Spec

> **Note:** this document was reconstructed from the implementation plan. Replace
> or extend it with the original product brief, keeping the section numbering —
> later phases cross-reference these sections (§3 stack, §6 performance, §7
> layout, §9 pre-flight).

## §1 Goal

Murmur is a fully local voice dictation app for macOS on Apple Silicon — a
privacy-first alternative to Wispr Flow. The user holds a hotkey, speaks, and
the transcribed text is inserted into whatever text field is focused, in any
app. No audio or text ever leaves the machine.

## §2 Principles

- **Fully local.** No telemetry. No network in the hot path. The single
  permitted network operation is the one-time model download from Hugging Face.
- **Runs on a 16 GB Apple Silicon machine** (M1, 16 GB is the reference
  hardware). Default models must fit comfortably.
- **Never crash on missing permissions** — detect, guide, degrade.
- **Latency is the product.** Text should appear ~300 ms after hotkey release.

## §3 Pinned stack

Do not re-litigate these choices:

| Concern | Choice |
|---|---|
| Runtime | Python ≥3.11, managed by `uv` |
| STT | `parakeet-mlx`, model `mlx-community/parakeet-tdt-0.6b-v3` (~1.2 GB) |
| LLM cleanup (Phase 3) | `mlx-lm`, default `mlx-community/Qwen3-4B-4bit` |
| Audio capture | `sounddevice` (16 kHz mono float32) |
| VAD (Phase 2) | `webrtcvad` (fallback: `webrtcvad-wheels`) |
| OS integration | `pyobjc` — Quartz event tap, NSPasteboard, ⌘V synthesis |
| Menu bar | `rumps` |

## §4 Hotkeys & UX

- **Push-to-talk:** hold `Fn`/Globe → record while held; release → transcribe +
  insert.
- **Hands-free toggle:** `Fn+Space` → start recording; `Esc` (or `Fn+Space`
  again) → stop → transcribe + insert. VAD auto-stop on silence is Phase 2;
  manual stop ships in Phase 1.
- All keys remappable via `~/.murmur/config.toml`.
- Requires System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**;
  first-run guidance must surface this.
- Menu bar icon mirrors state: 🎤 idle / 🔴 recording / ✍️ transcribing.

## §5 Architecture

```
main thread:        rumps app (owns the NSApplication run loop) + CGEventTap source
audio thread:       sounddevice InputStream callback → queue of PCM blocks
STT worker thread:  owns the Parakeet model; consumes the queue, feeds
                    transcribe_stream() while recording → finalize on stop
```

State machine: `IDLE → RECORDING(ptt|toggle) → TRANSCRIBING → IDLE`.

Insertion: save pasteboard → write transcript → synthesize ⌘V → restore the
old pasteboard only if no one else touched it in between (changeCount check).

## §6 Performance & logging

- Log model load time and process RSS at startup.
- Log one summary line per utterance with per-stage timings, e.g.
  `stt_finalize=82ms insert=14ms total=96ms`, measured from recording stop.
- Timing records accumulate in a JSON-exportable form (`--bench` report is
  Phase 6 work; collection starts in Phase 1).
- Budget: insertion within ~300 ms of hotkey release.
- Structured logs with millisecond timestamps, console + `~/.murmur/murmur.log`.

## §7 Repo layout

```
pyproject.toml  README.md  SPEC.md  config.example.toml  .gitignore
src/murmur/
    __init__.py  __main__.py  app.py  config.py  audio.py  stt.py  insert.py
    hotkey.py  menubar.py  permissions.py  bench.py
    vad.py  cleanup.py  context.py  hud.py  dictionary.py   (later phases)
scripts/preflight.py
tests/
```

## §8 Phase roadmap

- **Phase 0** — scaffold: packaging, config, logging, CLI skeleton.
- **Phase 1** — core dictation loop: hotkeys → record → Parakeet → paste-insert.
- **Phase 2** — HUD with live draft tokens; VAD endpointing (auto-stop).
- **Phase 3** — LLM cleanup pass (`mlx-lm`), off by default.
- **Phase 4** — tone profiles, custom dictionary, app context.
- **Phase 5** — command mode.
- **Phase 6** — performance budget work, `--bench` report.
- Later: native Swift/ANE rewrite (`docs/native-swift-path.md`).

## §9 Pre-flight

Before building on a new machine, verify the model path works:
generate a test WAV (`say -o test.aiff "..."` then `afconvert` to 16 kHz mono
WAV), load `parakeet-tdt-0.6b-v3` via `parakeet-mlx`, transcribe, and print
load time + transcript. Shipped as `scripts/preflight.py`.
