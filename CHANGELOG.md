# Changelog

All notable changes to Pomvox are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The `[stt] model` setting did nothing.** The native engine always loaded the
  v3 speech model regardless of the configured value. It now honors the setting
  (v2 or v3), and falls back to v3 (with a log line) for an unrecognized value,
  so a typo never stops the engine from arming.

## [0.1.8] — 2026-07-07

### Fixed

- **The dictation hotkey was locked to Fn.** Changing the push-to-talk key in
  Settings ▸ Hotkeys had no effect — the native engine ignored the `[hotkey]`
  configuration entirely, leaving no workaround for keyboards that handle Fn in
  hardware. The engine now honors the configured key, and degrades safely back
  to the Fn defaults (with a log line) if the configuration is invalid, so
  dictation never breaks. (#61)

- **Dictation looked broken when your Dictionary rules removed every word.** If
  your replacement rules deleted all of the recognized text, the app pasted
  nothing and gave no hint why — indistinguishable from not being heard. It now
  flashes "your replacement rules removed every word — check Settings ▸
  Dictionary" instead of failing silently. Long HUD messages also wrap to two
  lines instead of being truncated. (#62)

## [0.1.7] — 2026-07-06

### Fixed

- **Dictation could die silently after deep sleep.** A long sleep could leave
  the microphone engine delivering a dead (all-zero) stream — recordings
  captured audio but transcribed to nothing, with no explanation. The audio
  engine is now rebuilt after sleep and whenever the input device
  configuration changes. (#60)

- **Fresh installs had a silent dead zone during the first-run download.**
  The dictation hotkey only became active after the ~460 MB speech-model
  download, so pressing Fn right after installing did nothing at all. The
  hotkey now works immediately: a press during the download shows
  "not ready yet — downloading NN%" on the HUD. (#60)

- **A hotkey press racing engine startup could corrupt the engine state.**
  Stop/cancel/hands-free events arriving before the engine was ready could
  flip it to "ready" mid-download or fake a transcription cycle; every
  terminal transition is now status-guarded. A wake during the download can
  no longer strand a dead hotkey tap or crash on the next keypress. (#60)

### Added

- **Every "nothing happened" now explains itself.** The HUD logs its
  show/hide lifecycle and verifies against the window server that the pill
  is actually on screen; empty transcripts are classified (mic captured
  silence vs transcription failure vs genuinely no words) and the two hard
  failures flash the reason on the HUD. (#60)

- **Setup shows a live hotkey heartbeat.** A new row in the Setup checklist
  turns green when Fn actually reaches Pomvox — separating "permission not
  effective until relaunch" and "this keyboard handles Fn in hardware" from
  everything else. (#60)

- **`scripts/verify-hud.sh`** — an end-to-end check that synthesizes an Fn
  press and asks the window server whether the HUD pill really appeared. (#60)

## [0.1.6] — 2026-07-05

### Added

- **First-run model downloads now show progress.** The first time the native
  engine turns on it fetches a ~460 MB speech model (and, in the background, a
  larger cleanup model). Until now the menu bar just read a static
  "Preparing…", so the first use looked like a hang. It now shows a live
  "Downloading the speech model… NN%" in the menu bar and Settings, and a
  background note while the cleanup model finishes.

- **First launch guides you to Setup.** Pomvox needs Microphone, Input
  Monitoring, and Accessibility before it can do anything, but a fresh install
  opened to an empty dashboard with no hint. The Hub now opens straight to the
  Setup checklist whenever a grant is still missing, the menu bar offers
  "Finish setup — grant permissions…", and the sidebar flags the Setup row.

### Fixed

- **A Mac with no microphone got the wrong advice.** A capture failure always
  suggested granting Microphone permission — useless on a machine with no input
  device at all. Pomvox now tells those apart and shows "No microphone found —
  connect one and try again." when no device is present.

## [0.1.5] — 2026-07-05

### Fixed

- **Home greeting showed a hardcoded name.** The Hub's greeting had the
  maintainer's first name baked in, so every install read "Good morning, Abhi."
  It now uses the Mac account's own name (`NSFullUserName`), falling back to a
  name-less greeting when the account has no full name set.

## [0.1.4] — 2026-07-05

### Changed

- **Telemetry is now an explicit first-run choice, not on-by-default.** On first
  launch Pomvox shows a screen with two equal-weight buttons — **Share anonymous
  stats** / **No thanks** — with no pre-selected default. Nothing is sent (or even
  queued) unless you choose to share; the choice is stored as a tri-state
  (`granted` / `denied` / `undecided`) and is changeable anytime in Settings →
  Privacy. Existing installs from 0.1.3 (which defaulted on) are reset to
  undecided and shown the choice screen. Supersedes the 0.1.3 opt-out behavior.

## [0.1.3] — 2026-07-05

### Changed

- **Anonymous usage stats are now on by default (opt-out).** Previously opt-in.
  They remain anonymous and content-free (a random install ID plus counters —
  never audio, transcripts, or any free text), and **nothing is sent until the
  first-run disclosure has been shown** (the `maySend` gate). The disclosure has
  an equal-weight one-tap **Turn off**, and you can turn it off anytime in
  Settings → Privacy. Docs and the in-app copy updated to match.

## [0.1.2] — 2026-07-05

### Fixed

- **Dictation hotkey dead after a long sleep.** The 0.1.1 fix handled short
  sleeps but not deep sleep/standby: macOS stops delivering events to the global
  event tap even though it still reports "enabled", so re-enabling it wasn't
  enough — the hotkey stayed dead (no HUD, no dictation) until the app was
  restarted. Pomvox now **rebuilds the event tap from scratch on wake** (on both
  `didWake` and `screensDidWake`, after a short settle), which is the only
  reliable recovery. Verified on-device.

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

[Unreleased]: https://github.com/abhiram304/pomvox/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/abhiram304/pomvox/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/abhiram304/pomvox/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/abhiram304/pomvox/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/abhiram304/pomvox/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/abhiram304/pomvox/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/abhiram304/pomvox/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/abhiram304/pomvox/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/abhiram304/pomvox/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/abhiram304/pomvox/releases/tag/v0.1.0
