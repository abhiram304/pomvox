# Pomvox — product spec & roadmap

This is the product specification and roadmap: what Pomvox is, the principles it
holds to, and where it's going. [ARCHITECTURE.md](ARCHITECTURE.md) documents the
system **as implemented** (and carries the measured numbers); when the two
disagree about the present, ARCHITECTURE wins.

## What Pomvox is

**Pomvox** is a fully local, open-source, privacy-first voice dictation app for
macOS on Apple Silicon — an alternative to Wispr Flow. The user holds a global
hotkey, speaks, and clean, formatted text is inserted into whatever text field is
focused, in any app. No audio ever leaves the machine.

What makes Pomvox more than "press a key and get a raw transcript" is a
**two-stage pipeline**: a fast speech-to-text model produces the raw transcript,
then a small local LLM cleans it up — strips filler words ("um", "uh", "like"),
fixes punctuation and casing, formats lists, and resolves spoken self-corrections
(e.g. "let's meet Tuesday, wait no, Friday" → "Let's meet Friday"). Both stages
run on-device.

Reference hardware is an Apple Silicon Mac (M1, 16 GB); the default config is
tuned to run there. Larger machines can swap in bigger models for quality (models
are config values).

## Status

The core product is built and is the daily driver — a native SwiftUI menu-bar app
(`Pomvox.app`):

- ✅ Hold-hotkey dictation (push-to-talk + hands-free), insertion into any app via
  the pasteboard + ⌘V.
- ✅ Live HUD with a two-tone draft as you speak; VAD auto-stop on a natural
  pause; Esc-cancel.
- ✅ Local LLM cleanup (Qwen3 on the GPU) with a deadline and raw-text fallback.
- ✅ Speech-to-text on the **Neural Engine** (FluidAudio / Parakeet), leaving the
  GPU free for cleanup.
- ✅ Hub window (dashboard, searchable history, settings), native onboarding /
  permission walkthrough, launch-at-login.
- ✅ Bounded, transcripts-only history (sqlite, default 7-day retention).
- ✅ Custom dictionary (Phase 4) — proper-noun spellings + misheard-term fixups,
  in both engines.

What's next:

- **Distribution** — Developer ID + notarization, a signed download, and a
  Homebrew cask (today the app is built from source).
- **Context-aware tone** (rest of Phase 4) — `context.py` is a docstring-only
  seam.
- **Command Mode** (Phase 5, stretch).

The project began as a Python app; that engine still ships in the repo as a
runnable reference and the cross-checked test spec (see
[ARCHITECTURE.md](ARCHITECTURE.md)).

## Principles

1. **Local-first.** No network calls in the hot path; your voice and transcripts
   never leave the machine. Network is limited to the one-time model download
   and — only if the user opts in — anonymous, content-free usage stats (off by
   default, native app only). This is the product's reason to exist; that opt-in
   telemetry is the one cloud feature, built the only acceptable way: explicit,
   off by default, anonymous, no content, clearly labeled.
2. **Latency is a feature.** Treat it like a real-time system — from hotkey
   release to inserted text should feel instant. Every stage is instrumented and
   logged per utterance.
3. **Works everywhere.** Insertion lands in arbitrary native and Electron apps
   (Mail, Slack, Notes, Chrome, VS Code, Cursor, Terminal).
4. **Degrade gracefully.** If the cleanup stage is slow or fails, fall back to
   inserting the raw transcript rather than blocking. Never lose the user's words.

## Pipeline

```
[Global hotkey]  push-to-talk (hold) or hands-free (toggle)
   │
   ▼
[Mic capture] ──16 kHz mono──► [buffer]
   │
   ▼
[VAD / endpointing]  speech start + end-of-utterance silence (hands-free)
   │
   ▼
[STT]  Parakeet on the Neural Engine; a live HUD shows the draft as you speak
   │   (on hotkey release OR end-of-utterance)
   ▼
[LLM cleanup]  Qwen3 on the GPU — strip fillers, punctuate, format, resolve
   │           self-corrections; deadline + raw-text fallback
   ▼
[Text insertion]  pasteboard + synthesized ⌘V into the focused field
   │
   ▼
[History]  transcripts-only sqlite row, off the latency path
```

A never-steals-focus **HUD** shows recording state and the live draft; the
**menu-bar app** owns state, settings, and the Hub window.

## Tech stack

**Native app (`Pomvox/`, the daily driver)** — Swift + SwiftUI, macOS 14+:

- **STT:** [FluidAudio](https://github.com/FluidInference/FluidAudio) running
  Parakeet TDT (`mlx-community/parakeet-tdt-0.6b-v2`, English-only; the
  multilingual `…-v3` is selectable via `[stt] model`) as CoreML on the Neural
  Engine.
- **Cleanup LLM:** [mlx-swift](https://github.com/ml-explore/mlx-swift) running a
  small 4-bit instruct model (default Qwen3-4B-4bit) on the GPU. Model ids are
  config values.
- **App shell:** SwiftUI `MenuBarExtra` + a `Window` Hub; a non-activating
  `NSPanel` HUD; CGEventTap hotkey; `NSPasteboard` + synthesized ⌘V; SMAppService
  launch-at-login.

**Python reference engine (`src/pomvox/`)** — the original implementation, frozen
as a runnable reference and the spec the Swift ports are checked against:
`parakeet-mlx` (STT on the GPU), `mlx-lm` (cleanup), `sounddevice`, `webrtcvad`,
`pyobjc`, `rumps`. Its pure-logic modules are Linux-tested and gate the Swift
behavior vector-for-vector.

## macOS permissions

The app needs, and guides the user to grant (via the in-app Setup walkthrough):

- **Microphone** — capture.
- **Accessibility** — synthesize the ⌘V keystroke / read focus.
- **Input Monitoring** — the global hotkey event tap.

Missing permissions are detected and surfaced (with deep links into the right
System Settings pane via the `x-apple.systempreferences:` URL scheme), never
crashed or silently no-op'd. macOS keys these grants to the app's code identity,
so the build uses a stable signing certificate (see CONTRIBUTING).

## Roadmap

The phases below are the product definition; their acceptance criteria are the
spec each stage is held to. Phases 0–3 and the native rewrite are shipped; the
acceptance criteria remain the regression bar.

### Phase 0 — Scaffold ✅
Config (`~/.pomvox/config.toml`: hotkey, models, cleanup, insertion), structured
logging with millisecond timings.

### Phase 1 — Core dictation loop ✅
Hold-hotkey → capture → STT → insert into the focused field via pasteboard + ⌘V;
menu-bar state. **Acceptance:** in Notes, TextEdit, and Slack, holding the hotkey
and speaking a sentence inserts the correct transcript within ~300 ms of release
(cleanup off); logs show per-stage timings.

### Phase 2 — Live HUD + endpointing ✅
A never-steals-focus HUD showing a live two-tone draft; VAD endpointing so
hands-free mode auto-finalizes on silence. **Acceptance:** draft updates visibly
while speaking; HUD never steals focus; toggle mode finalizes on a natural pause.

### Phase 3 — LLM cleanup ✅
Finalized transcript through the local LLM: remove fillers, fix punctuation/
casing, format lists, resolve self-corrections — **without** changing meaning or
adding content; deadline + raw-text fallback; toggleable. **Acceptance:** "um so
the three things are uh first do the thing wait no two things first do the thing
and second ship it" → "The two things: first, do the thing; second, ship it."
Raw-fallback works when the LLM is killed mid-request.

### Phase 4 — Context-aware tone + custom dictionary
**Custom dictionary ✅** (both engines): proper nouns / jargon injected into the
cleanup prompt, plus literal misheard→correct fixups applied to the final text
even when cleanup is off/times out. "Salammagari" / "parakeet-mlx" come out
spelled right.

**Context-aware tone (next):** read `NSWorkspace.frontmostApplication`; map
bundle IDs to tone profiles (Mail → formal, Slack/Messages → casual,
editors/terminals → verbatim) selecting the cleanup prompt. **Acceptance:** the
same spoken input yields a formal version in Mail and a casual one in Slack.
(`context.py` is a docstring-only seam today.)

### Phase 5 — Command Mode (stretch)
Select text in any app, press a second hotkey, speak a transform ("make this more
concise", "turn this into bullet points"); Pomvox reads the selection, runs it
through the LLM, and replaces it in place.

## Performance budgets

Targets the system is instrumented against (per-utterance `bench:` / `cleanup:
gen` log lines and the `timings_json` history column carry the live numbers; the
**measured** M1 figures live in [ARCHITECTURE.md](ARCHITECTURE.md)):

- Hotkey release → STT finalized: fast (one transcribe of the buffered tail).
- Total release → inserted text, **cleanup OFF: < 300 ms**.
- Cleanup ON: bounded by the configurable deadline, with raw-text fallback so the
  paste is never held hostage.
- Idle footprint and model load time reported at startup.

## Repo layout

```
pomvox/
  Pomvox/                 # native Swift app (daily driver)
    project.yml           #   XcodeGen spec → Pomvox.xcodeproj
    Sources/              #   SwiftUI Hub + Engine/ (STT, cleanup, HUD, history…)
    Tests/                #   XCTest ports of the pure-logic spec
  src/pomvox/             # Python reference engine + the pure-logic spec
    audio · stt · cleanup · insert · hud · vad · history · onboarding · …
  tests/                  # Linux-testable spec suite (the Swift ports' vectors)
  scripts/                # dev signing cert, preflight, benches
  docs/                   # design + native-swift-path notes
```

## Out of scope (documented, not built)

- iOS / Windows. macOS Apple Silicon only.
- Speaker diarization, multi-speaker meeting transcription.
- Any cloud sync or account system. (The sole network exception is opt-in,
  anonymous, content-free usage stats — off by default; see Principle 1.)
