# Murmur — Claude Code Build Brief

> Paste this whole file into Claude Code as the opening prompt, or save it as
> `SPEC.md` at the repo root and tell Claude Code: "Read SPEC.md and start on
> Phase 1." It is written to be self-contained.

---

## 0. What you're building

**Murmur** is a fully local, open-source, privacy-first voice dictation app for
macOS on Apple Silicon — an alternative to Wispr Flow. The user holds a global
hotkey, speaks, and clean, formatted text is inserted into whatever text field
is focused, in any app. No audio ever leaves the machine.

The thing that makes Murmur more than "press a key and get raw transcript" is a
**two-stage pipeline**: a fast streaming speech-to-text model produces the raw
transcript, then a small local LLM cleans it up — strips filler words ("um",
"uh", "like"), fixes punctuation and casing, formats lists, and resolves spoken
self-corrections (e.g. "let's meet Tuesday, wait no, Friday" → "Let's meet
Friday"). Both stages run on-device via Apple's MLX framework.

Target hardware: Apple Silicon (M1 or later). Primary dev/test machine is a Mac
Studio M3 Ultra with 512 GB unified memory, so memory is not a constraint — but
keep the default config runnable on a 16–32 GB MacBook.

---

## 1. Non-negotiable principles

1. **Local-only by default.** No network calls in the hot path. No telemetry.
   This is the product's reason to exist; do not add a cloud fallback unless it
   is explicitly opt-in, off by default, and clearly labeled.
2. **Latency is a feature.** Treat this like a real-time system. From hotkey
   release to inserted text should feel instant. Instrument and log timings.
3. **Works everywhere.** Insertion must land in arbitrary native and Electron
   apps (Mail, Slack, Notes, Chrome, VS Code, Cursor, Terminal).
4. **Degrade gracefully.** If the LLM cleanup stage is slow or fails, fall back
   to inserting the raw STT transcript rather than blocking.

---

## 2. Reference architecture (the pipeline)

```
[Global hotkey]
   │  (push-to-talk: hold to record / toggle mode optional)
   ▼
[Mic capture] ──16kHz mono PCM──► [Ring buffer]
   │
   ▼
[VAD / endpointing]  ── detect speech start + end-of-utterance silence
   │
   ▼
[STT: parakeet-mlx streaming]  ── transcribe_stream(), emits finalized + draft tokens
   │        (live HUD shows draft text as you speak)
   ▼  (on hotkey release OR end-of-utterance)
[LLM cleanup: mlx-lm]  ── strip fillers, punctuate, format, resolve corrections,
   │                        tone profile chosen from frontmost app
   ▼
[Text insertion]  ── pasteboard + synthesized ⌘V into focused field
```

A small always-on-top **HUD** shows recording state and the live draft
transcript. A **menu-bar app** owns settings, model selection, and history.

---

## 3. Tech stack (pinned decisions — don't re-litigate these in Phase 1)

- **Language:** Python 3.11+, managed with `uv`.
- **STT:** [`parakeet-mlx`](https://github.com/senstella/parakeet-mlx),
  model `mlx-community/parakeet-tdt-0.6b-v3` (multilingual, ~25 langs, SOTA WER,
  faster-than-realtime). Use its `transcribe_stream(context_size=(256, 256))`
  streaming context; read `transcriber.result`, `finalized_tokens`, and
  `draft_tokens`.
- **Cleanup LLM:** [`mlx-lm`](https://github.com/ml-explore/mlx-lm). Default to a
  small fast instruct model (e.g. a 3–4B class model at 4-bit) so latency stays
  low. Make the model id a config value; on the 512 GB box the user may swap in
  something larger for quality. Keep `max_tokens` tight and stream the output.
- **Audio capture:** `sounddevice` (PortAudio), 16 kHz mono, small block size.
- **VAD / endpointing:** `webrtcvad` for the MVP; leave a clean seam to swap in
  Silero VAD later.
- **Global hotkey + keystroke synthesis + frontmost app + pasteboard:** `pyobjc`
  (Quartz `CGEventTap` for the hotkey and ⌘V synthesis, `AppKit`
  `NSWorkspace.frontmostApplication` for app context, `NSPasteboard` for
  insertion). Use `pynput` only if `pyobjc` event taps prove painful — prefer
  pyobjc for reliability under macOS permissions.
- **Menu-bar app:** `rumps`.
- **HUD overlay:** a small borderless always-on-top `NSPanel` via pyobjc
  (non-activating, so it doesn't steal focus from the target text field).

> Reasoning notes for context (do not need to act on these in Phase 1):
> Parakeet on MLX runs on the **GPU**, which is fine here but monopolizes it.
> The eventual "real app" path (see §8) is a native Swift menu-bar app using
> `FluidAudio` / `swift-parakeet-mlx` to run Parakeet on the **Neural Engine**
> via CoreML, leaving the GPU free. We are deliberately starting in Python for
> speed of iteration.

---

## 4. macOS permissions (handle these explicitly)

The app needs, and must guide the user to grant:
- **Microphone** (capture).
- **Accessibility** (synthesize the ⌘V keystroke / read focus).
- **Input Monitoring** (global hotkey via event tap).

On first run, detect missing permissions and show a clear, actionable prompt
(open the right System Settings pane via the
`x-apple.systempreferences:` URL scheme). Do not crash or silently no-op when a
permission is missing — surface it in the menu bar.

---

## 5. Build plan (phased, with acceptance criteria)

Work phase by phase. Do not start a phase until the previous one's acceptance
criteria pass. Commit at the end of each phase with a clear message.

### Phase 0 — Scaffold
- `uv` project, `pyproject.toml`, pinned deps, `README.md`, `SPEC.md`.
- Config module reading a `~/.murmur/config.toml` (hotkey, STT model, LLM model,
  cleanup on/off, insertion method).
- Structured logging with millisecond timestamps.
- **Acceptance:** `uv run murmur --version` works; config loads; logs write.

### Phase 1 — Core dictation loop (the MVP that already beats raw OS dictation)
- Hold-hotkey → capture mic → stream into `parakeet-mlx` → on release, insert
  the transcript into the focused field via pasteboard + ⌘V.
- Cleanup LLM **off** in this phase — prove the transcription + insertion path.
- Menu-bar icon shows idle / recording / transcribing states.
- **Acceptance:** In Notes, TextEdit, and Slack, holding the hotkey and speaking
  a sentence inserts the correct transcript within ~300 ms of release. Logs show
  per-stage timings.

### Phase 2 — Live HUD + endpointing
- Borderless always-on-top HUD near the cursor/bottom of screen showing a
  recording animation and the live draft transcript (`draft_tokens`).
- `webrtcvad` endpointing so hands-free/toggle mode can auto-finalize on silence.
- **Acceptance:** Draft text updates visibly while speaking; HUD never steals
  focus; toggle mode finalizes on a natural pause.

### Phase 3 — LLM cleanup layer
- Pipe finalized transcript through `mlx-lm` with a cleanup system prompt that:
  removes fillers, fixes punctuation/casing, formats obvious lists, and resolves
  self-corrections — **without** changing meaning or adding content.
- Stream tokens; enforce a latency budget; on timeout/error, insert raw text.
- Make cleanup toggleable from the menu bar.
- **Acceptance:** "um so the three things are uh first do the thing wait no two
  things first do the thing and second ship it" →
  "The two things: first, do the thing; second, ship it." Raw-fallback works
  when the LLM is killed mid-request.

### Phase 4 — Context-aware tone + custom dictionary
- Read `NSWorkspace.frontmostApplication`; map bundle IDs to tone profiles
  (Mail → polished/formal, Slack/Messages → casual, VS Code/Cursor/Terminal →
  verbatim/code-aware, minimal rewriting). Profile selects the cleanup prompt.
- User dictionary in config (proper nouns, jargon, spellings) injected into the
  cleanup prompt and applied as post-replacements.
- **Acceptance:** Same spoken input yields a formal version in Mail and a casual
  one in Slack; dictating "Salammagari" / "parakeet-mlx" comes out spelled right.

### Phase 5 (stretch) — Command Mode
- Select text in any app, press a second hotkey, speak a transform
  ("make this more concise", "turn this into bullet points"); Murmur reads the
  selection (Accessibility API / copy), runs it through the LLM, replaces it.
- **Acceptance:** Selecting a paragraph and saying "make this concise" replaces
  it with a shorter version in place.

---

## 6. Performance budgets (instrument and report against these)

Log each stage and surface a `--bench` mode that prints a summary table. Targets
on M3-class hardware:
- Hotkey release → STT finalized: **< 150 ms** after last audio.
- Cleanup LLM (3–4B, 4-bit), typical 1–2 sentence utterance: **< 600 ms**.
- Total release → inserted text, cleanup ON: **< 900 ms**; cleanup OFF: **< 300 ms**.
- Idle memory footprint and model load time reported at startup.

(These numbers map nicely onto a benchmark write-up later — keep the timing
collection clean and exportable to JSON/CSV.)

---

## 7. Repo layout (suggested)

```
murmur/
  pyproject.toml
  README.md
  SPEC.md
  config.example.toml
  src/murmur/
    __main__.py          # entrypoint / CLI
    config.py
    audio.py             # capture + ring buffer
    vad.py               # endpointing
    stt.py               # parakeet-mlx streaming wrapper
    cleanup.py           # mlx-lm cleanup + tone profiles
    insert.py            # pasteboard + CGEvent ⌘V
    context.py           # frontmost app → tone profile
    hud.py               # NSPanel overlay
    menubar.py           # rumps app
    permissions.py       # detect + guide
    bench.py             # timing + report
    dictionary.py
  tests/
```

## 8. Out of scope for now (document, don't build)

- iOS/Windows. macOS Apple Silicon only.
- A native **Swift** rewrite that runs Parakeet on the **Neural Engine** via
  `FluidAudio` / `swift-parakeet-mlx` (keeps the GPU free, better battery, the
  path to a notarized shippable `.app`). Add a `docs/native-swift-path.md` stub
  describing this as the v2 so the architecture is captured, but do not build it.
- Speaker diarization, multi-speaker meeting transcription.
- Any cloud sync, account system, or telemetry.

## 9. Your first move

Start with Phase 0, then Phase 1. Before writing code, confirm the dependency
versions resolve under `uv` on macOS and that `parakeet-mlx` can load
`mlx-community/parakeet-tdt-0.6b-v3` and transcribe a test WAV. Then build the
hotkey→capture→STT→insert loop end to end. Show me the per-stage timing log when
Phase 1's acceptance test passes.
