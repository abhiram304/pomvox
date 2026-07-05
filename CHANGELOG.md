# Changelog

All notable changes to Pomvox are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.1.1] — 2026-07-04

### Fixed

- **Stuck recording across system sleep/wake.** After the Mac slept and woke,
  the microphone could stay "recording" with no HUD, recoverable only by
  restarting the app. macOS disables the global event tap across sleep and the
  push-to-talk key-up that stops recording could be dropped, stranding the
  hotkey state machine. Pomvox now resets to a clean armed-idle state around
  sleep/wake (stopping any live capture and hiding the HUD) and re-asserts the
  event tap on wake.

## [0.1.0] — 2026-07-03

First public release. A fully local, privacy-first voice-dictation app for macOS
on Apple Silicon, shipping as a signed, notarized `Pomvox.dmg`.

### Added

- **Native SwiftUI menu-bar app** (`Pomvox.app`) — runs from the menu bar, can
  launch at login, and arms the dictation hotkey with zero clicks.
- **On-device speech-to-text** on the Neural Engine (parakeet-tdt-0.6b-v3 via
  FluidAudio) — voice and transcripts never leave the machine.
- **Optional local cleanup pass** — a small LLM runs on the GPU (mlx-swift) to
  fix fillers and punctuation (`light`) or smooth rambles (`polish`); on timeout
  the raw transcript is inserted, so words are never lost.
- **Push-to-talk and hands-free** dictation — hold `Fn` to talk, or `Fn+Space`
  for hands-free with auto-stop on a natural pause; `Esc` cancels.
- **Live two-tone HUD** — settled words bright, newest chunk dimmed, then a
  "finishing…" state during cleanup.
- **The Hub window** — Home (words / dictations / WPM stats and a 30-day activity
  strip), History (raw vs. cleaned, search, copy / re-insert / delete), Settings
  (models, hotkeys, cleanup, HUD, launch-at-login), and a Setup walkthrough for
  the three permissions with a live insertion self-test.
- **Local, transcripts-only history** at `~/.pomvox/history.db` — audio is never
  stored; rows auto-delete after a configurable retention window.
- **Comment-preserving TOML config** at `~/.pomvox/config.toml` — models,
  hotkeys, cleanup, and history are all configurable; anything model-shaped is a
  config value, never a constant.
- **Opt-in, anonymous, content-free telemetry** — off by default, with a one-time
  in-app prompt and a Privacy pane that spells out exactly what's sent. It can
  never carry audio, transcripts, or free text.
- **Custom dictionary** — user-defined words and misheard-term fixups.
- **Signed & notarized distribution** — Developer ID signing, hardened runtime,
  and Apple notarization; the `Pomvox.dmg` opens with no right-click bypass.
- **App icon** — an ember waveform on an espresso background.
- **Python reference engine** (`src/pomvox/`) — the original app, now frozen as a
  runnable reference whose pure-logic modules are the cross-checked test spec.

[Unreleased]: https://github.com/abhiram304/pomvox/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/abhiram304/pomvox/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/abhiram304/pomvox/releases/tag/v0.1.0
