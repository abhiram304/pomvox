# Murmur

Fully local, privacy-first voice dictation for macOS on Apple Silicon. Hold a
hotkey, speak, and the transcript is inserted into whatever text field is
focused — in any app. No audio or text ever leaves your machine (the only
network operation is the one-time model download from Hugging Face).

See [SPEC.md](SPEC.md) for the full product spec,
[ARCHITECTURE.md](ARCHITECTURE.md) for how the implemented system fits
together, and [CONTRIBUTING.md](CONTRIBUTING.md) to get involved.

## Requirements

- Apple Silicon Mac (reference hardware: M1, 16 GB), macOS 14+
- [`uv`](https://docs.astral.sh/uv/)

## Quick start

```sh
uv sync
uv run python scripts/preflight.py   # downloads parakeet-tdt-0.6b-v3 (~1.2 GB), transcribes a test WAV
uv run murmur --check                # permission report
uv run murmur                        # menu bar app
```

## First run checklist

1. **Permissions** — `uv run murmur --check` reports what's missing. Grant in
   System Settings → Privacy & Security:
   - **Microphone** (recording)
   - **Accessibility** (synthesizing ⌘V to paste the transcript)
   - **Input Monitoring** (the global hotkey event tap)
2. **Globe key** — System Settings → Keyboard → "Press 🌐 key to" →
   **Do Nothing**, otherwise macOS intercepts the Fn key before Murmur sees it.
   `murmur --check` warns if this is set wrong.

> **Dev note:** while running via `uv run` from a terminal, the TCC permission
> grants attach to the *terminal app* (Terminal.app, iTerm2, …), not to
> Murmur. If hotkeys or pasting silently do nothing, re-check the grants for
> the terminal you're launching from. After changing grants, restart the
> terminal.

## Usage

- **Push-to-talk:** hold `Fn`, speak, release → text appears at the cursor.
- **Hands-free:** press `Fn+Space` to start; `Fn+Space` again (or a tap of
  `Fn`) to stop and insert. (Auto-stop on silence arrives in Phase 2.)
- **Cancel:** `Esc` while recording (either mode) discards the utterance —
  nothing is inserted.

> **Breaking change:** `Esc` used to *stop and insert* in hands-free mode;
> it now *cancels*. Set `[hotkey] cancel = ""` and `stop = "esc"` in
> `~/.murmur/config.toml` to restore the old behavior.

Menu bar icon: 🎤 idle · 🔴 recording · ✍️ transcribing.

## Configuration

Copy [`config.example.toml`](config.example.toml) to `~/.murmur/config.toml`.
Every key is optional. Highlights:

- `[hotkey] ptt` — set to `"right_option"` if Fn interception is unreliable on
  your machine.
- `[log] file` — set `false` to disable `~/.murmur/murmur.log`.

The menu bar has **Open Config File** and **Reload Config** — edits to
styles, HUD, and auto-stop apply without a restart (model and hotkey
changes still need one; the status line says so). **Copy Last Transcript**
recovers the most recent dictation if a paste ever fails.

**History…** shows your recent dictations (raw vs. cleaned side by side)
with search, copy, re-insert, and delete. It is local-only sqlite at
`~/.murmur/history.db`: transcripts only — audio is never stored — and
rows auto-delete after `[history] retention_days` (default 7; `0` keeps
nothing, `enabled = false` writes nothing).

Logs include one line per utterance with stage timings
(`stt_finalize=82ms insert=14ms total=96ms`).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). Pure-logic modules (`config`,
`hotkey` state machine, `bench`, the prompt/guard half of `cleanup`) have no
macOS dependencies, so the test suite runs anywhere:

```sh
uv run pytest
```

Known build quirk: `webrtcvad` (used from Phase 2) ships source-only; if the
clang build fails, swap the dependency to `webrtcvad-wheels` (drop-in fork).

### The Hub (native macOS app)

Murmur is migrating to a native Swift app — see
[docs/native-swift-path.md](docs/native-swift-path.md). The first piece is the
**Hub**, a read-only SwiftUI main window (dashboard + history) that opens from
the menu bar's *Open Hub…* item. It reads `~/.murmur/history.db` in a separate
process, so it adds zero latency to dictation.

```sh
brew install xcodegen                 # one-time
cd Murmur && xcodegen generate        # regenerate Murmur.xcodeproj from project.yml
xcodebuild -project Murmur.xcodeproj -scheme Murmur -derivedDataPath /tmp/murmur-hub-dd build
open /tmp/murmur-hub-dd/Build/Products/Debug/Murmur.app
```

Build to a derived-data path **outside** an iCloud-synced folder (e.g. `/tmp`);
iCloud attaches extended attributes that make codesign reject the bundle. The
design reference is [docs/design/hub-mockup.html](docs/design/hub-mockup.html).
