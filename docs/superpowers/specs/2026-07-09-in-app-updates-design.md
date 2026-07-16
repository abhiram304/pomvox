# In-App Updates — Design Spec

**Date:** 2026-07-09 (re-validated 2026-07-15)
**Status:** Approved (brainstorm complete; implementation plan to follow)
**Baseline:** main @ v0.1.9 (`33797c4`); re-validated against main @ `bff5c5f` (post-Dictionary-v2)

## Re-validation (2026-07-15)

Before implementation, every contested decision was re-weighed against current
priorities (no bloat, privacy, simplest install UX). Outcome: **the design
stands unchanged.** Specifics:

- **Sparkle vs hand-rolled, weighed honestly both ways.** A minimal hand-rolled
  updater (~400 lines: fetch static feed → compare → download zip → verify via
  `codesign`/`spctl` + team-ID check → swap → relaunch) is feasible and could
  even skip EdDSA by leaning on notarization checks alone. Rejected anyway:
  the risk concentrates in the atomic-swap/relaunch path (rollback on partial
  copy, translocation, quarantine xattrs, admin escalation, running-from-DMG,
  download resume, downgrade refusal, macOS drift) — where a bug bricks the
  install and can destroy the very TCC grants this feature exists to preserve.
  Sparkle 2 headless costs one SPM dependency (~5 MB, no transitive deps);
  "no bloat" is served better by no custom install machinery to maintain.
- **Check policy re-settled with the user.** Three options laid out
  (on-by-default / first-run tri-state choice alongside telemetry consent /
  strict opt-in). **On-by-default confirmed** — an unpatched dictation app
  holding mic + input-monitoring + accessibility grants is a bigger privacy
  risk than a daily anonymous file GET (IP + User-Agent only; Sparkle's
  system profiling stays off). Mitigations stand: Settings toggle, visible
  **"last checked" time** (`updater.lastUpdateCheckDate`), "Check Now",
  README/SECURITY disclosure, zero checks in Debug builds.
- **TCC preservation confirmed — the reason this beats uninstall/reinstall.**
  TCC grants are stored against the bundle ID plus a code-signing requirement
  (`csreq`) — effectively `identifier "app.pomvox.hub"` + Developer ID leaf
  from team `CT84AT52RS`. An update signed by the same team with the same
  bundle ID still satisfies the stored requirement, so mic / input-monitoring
  / accessibility grants survive the in-place swap. On-device contrapositive
  (2× reproduced, 2026-07-13): swapping in a differently-signed local build
  invalidates the mic TCC row. Hard constraints: never change bundle ID or
  Developer ID team in an update; never rotate Developer ID and EdDSA
  together.

## Problem

Every Pomvox release currently requires users to manually download the new DMG
and reinstall. There is no in-app signal that a newer version exists. We want:
the app checks for updates automatically, quietly tells the user when one is
available, and a single click downloads, installs, and relaunches into the new
version.

## Decisions (made during brainstorm)

| Decision | Choice |
|---|---|
| Update policy | Auto-check in background (launch + every 24 h); install only when the user clicks Update. Never silent-install. |
| UX | Native Pomvox UI (hub banner + Settings controls). No stock Sparkle dialog, no popups. |
| Privacy | Checks on by default, with an "Automatically check for updates" toggle in Settings and README disclosure. (Updates are a security feature — different bar than telemetry, which stays strict opt-in.) |
| Engine | **Sparkle 2** (~2.9.x) via SPM, headless: `SPUUpdater` + custom `SPUUserDriver`. Rejected: stock Sparkle dialog (off-brand popup); roll-your-own GitHub API updater (we'd own translocation/atomic-swap/resume/signature edge cases Sparkle solved years ago — see Stats' updater bug history). |
| Appcast hosting | `appcast.xml` committed at the repo root on `main`, served via `https://raw.githubusercontent.com/abhiram304/pomvox/main/appcast.xml` (Maccy/AltTab pattern). |
| Enclosure | The existing notarized `Pomvox.zip` release asset (Sparkle's recommended `ditto` zip format). DMG stays the human-facing first-install download. |
| Homebrew | Cask gains `auto_updates true`; `livecheck` moves to `strategy :sparkle`. |
| Out of scope (YAGNI) | Delta updates, beta channels, phased rollouts, update telemetry events. The appcast format supports all of these later without breaking changes. |

## Architecture

### Engine

- Sparkle 2 added as an SPM package in `Pomvox/project.yml` (pin `2.9.x`).
- New `Pomvox/Sources/Updater.swift`: `UpdaterModel: ObservableObject` owning an
  `SPUUpdater` with a custom `SPUUserDriver`. The driver maps Sparkle callbacks
  onto one published state enum:

  ```
  idle → checking → updateAvailable(version, releaseNotesURL)
       → downloading(progress) → extracting → readyToRelaunch
       → installing | upToDate | error(message)
  ```

- One instance created at app startup, injected via the SwiftUI environment
  (same pattern as `HubModel`).
- Feed override for testing: if the `POMVOX_UPDATE_FEED` environment variable
  is set, the updater uses that URL as the feed. Otherwise (production path)
  startup calls `clearFeedURLFromUserDefaults()` so a stale test feed override
  can never hijack real updates (Sparkle-documented hardening). The test rig
  launches Developer ID-signed Release builds with this variable set.
- Debug builds: updater UI hidden and no scheduled checks (self-signed builds
  fail Sparkle's code-sign validation anyway), unless `POMVOX_UPDATE_FEED` is
  set for state-machine debugging.

### Info.plist keys (via project.yml)

| Key | Value |
|---|---|
| `SUFeedURL` | `https://raw.githubusercontent.com/abhiram304/pomvox/main/appcast.xml` |
| `SUPublicEDKey` | the new EdDSA public key |
| `SUEnableAutomaticChecks` | `YES` |
| `SUAutomaticallyUpdate` | `NO` (never installs without a click) |
| `SUScheduledCheckInterval` | `86400` |
| `SUVerifyUpdateBeforeExtraction` | `YES` (refuse bad signatures before unpacking) |
| `SUEnableJavaScript` | `NO` |

### UI surfaces

1. **Home view banner** — visible only in `updateAvailable`+ states:
   "Update available — vX.Y.Z" with **Update** and **Later** buttons and a
   release-notes link (the GitHub release page). Update drives inline progress
   (downloading % → preparing) through relaunch. **Later** hides the banner
   until next launch/check; "Skip this version" suppresses that version
   permanently (Sparkle-native).
2. **Settings ▸ General** — "Automatically check for updates" toggle (default
   on; maps to `updater.automaticallyChecksForUpdates`), "Check Now" button,
   current-version `InfoRow`, a visible "Last checked" time
   (`updater.lastUpdateCheckDate`, "Never" until the first check), inline
   "You're up to date" / error feedback.
3. Never a popup. Scheduled checks that find an update only light the banner.

### First run

Programmatically set `automaticallyChecksForUpdates = true` on first launch so
Sparkle's own "may I check automatically?" prompt never appears. Disclosed in
Settings and README.

### Dictation safety

Relaunch happens only as the direct result of the user pressing Update. If a
recording/transcription is in flight when install-and-relaunch is imminent,
wait for it to finish (engine state is already observable).

## Release pipeline

### One-time setup

- Run Sparkle `generate_keys`: private key → login Keychain; public key →
  `SUPublicEDKey`. Export one backup copy **offline** (losing the key strands
  all users) and store a copy as a GitHub Actions secret for future CI use.

### Per-release flow (extends `scripts/notarize-release.sh` / sibling script)

1. Build, sign, notarize as today → `dist/Pomvox.zip` + `dist/Pomvox.dmg`.
2. Sign the zip with the EdDSA key and generate the new appcast `<item>`
   (`generate_appcast --download-url-prefix
   https://github.com/abhiram304/pomvox/releases/download/vX.Y.Z/`, or
   `sign_update` + splice). Item carries version, `sparkle:edSignature`,
   length, `sparkle:minimumSystemVersion` (macOS 14), arm64 requirement.
3. **Order matters:** publish the GitHub release with assets *first*, then
   commit the updated `appcast.xml` to `main` — no client may ever see an
   appcast entry whose enclosure 404s.
4. Script validates before commit: well-formed XML, enclosure URL resolves
   (HTTP 200), EdDSA signature verifies against the public key.
5. Bump the Homebrew cask as usual (now with `auto_updates true`).

## Error handling

All failures render as inline UI; never a popup.

| Failure | Behavior |
|---|---|
| Scheduled check fails (offline / GitHub down / appcast 404) | Silent; log via `os.Logger` category `updater`; retry next interval. |
| Manual "Check Now" fails | Inline error in Settings ("Couldn't reach GitHub — check your connection"). |
| Download corrupt / EdDSA or code-sign validation fails | Sparkle refuses pre-extraction. UI: "Update couldn't be verified" + "Download manually" link to the releases page. |
| App translocated (quarantined run from ~/Downloads) | UI: "Move Pomvox to the Applications folder to enable updates." |
| /Applications needs admin | Sparkle's installer escalates with the standard macOS auth prompt. |
| Interrupted download | Sparkle persists and resumes on the next attempt. |
| Pre-updater installs (≤ v0.1.9) | One final manual update needed; release notes will say so. |

## Testing

### 1. Unit tests (XCTest, in CI)

- `UpdaterModel` state machine: every `SPUUserDriver` callback → correct
  published state; error paths → `error(message)`; Later/Skip behavior.
- Appcast script logic: version extraction, enclosure URL construction, XML
  well-formedness (fixture archives).
- Settings toggle ↔ `automaticallyChecksForUpdates` round-trip.

### 2. Scripted local end-to-end rehearsal (`scripts/verify-update.sh`)

1. Build two Developer ID-signed copies: "old" (current) and "new" (bumped).
2. Generate a local appcast for the new zip with a **throwaway test EdDSA
   key**; serve via `python3 -m http.server`.
3. Install old build in `~/Applications`; launch with
   `POMVOX_UPDATE_FEED=http://localhost:8000/appcast.xml`.
4. Verify: banner appears → Update → relaunch → installed bundle's
   `CFBundleShortVersionString` is the new version. Verification via
   `log stream` markers + reading the installed Info.plist (per the on-device
   verification playbook).

### 3. Edge-case matrix (manual, once for the feature)

- Tampered zip (one byte flipped) → "couldn't be verified" UI, no install.
- Wrong EdDSA key in appcast → same refusal.
- Appcast advertising an older version → no banner (downgrade protection).
- Kill app mid-download → relaunch → download resumes/completes.
- Offline scheduled check → silent, logged, no UI.
- Quarantined copy from ~/Downloads → "Move to Applications" guidance.
- Toggle off → zero update network calls on launch (verify via `log stream`).
- Dictation in flight when Update pressed → relaunch waits.

### 4. Release-pipeline dry run

Run the extended release script against a **draft** GitHub release + branch
appcast; point a local build's feed override at the branch raw URL; confirm a
real over-the-wire update from the GitHub CDN. Then the first real release
pair validates end-to-end: v0.2.0 ships the updater; v0.2.1 is the first
version delivered by it.

## Risks

- **EdDSA key loss** — unrecoverable; mitigated by offline backup + GH secret.
- **Key rotation hazard** — never rotate Developer ID and EdDSA key at the
  same time (breaks Sparkle's trust continuity).
- **raw.githubusercontent.com caching** — raw URLs can serve stale content for
  ~5 min after a commit; acceptable for a 24 h check cadence.
- **Homebrew auto-update semantics in flux** (Homebrew/brew #21985) —
  re-check cask conventions at cask-authoring time.
