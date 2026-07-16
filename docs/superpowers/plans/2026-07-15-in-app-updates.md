# In-App Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship in-app updates per `docs/superpowers/specs/2026-07-09-in-app-updates-design.md`: Sparkle 2 headless (custom driver, zero Sparkle UI), background checks at launch + every 24 h (on by default, Settings toggle), a native Home banner + Settings ▸ General group, one-click download → verify → install → relaunch that waits for in-flight dictation, and the appcast release pipeline.

**Architecture:** Sparkle 2 (SPM) provides checking, EdDSA + code-sign verification, atomic install, and relaunch. All UI is ours: `UpdaterModel` implements `SPUUserDriver` and maps every callback onto a pure `UpdaterState` reducer (unit-testable with no Sparkle types and no network). The feed is a static `appcast.xml` committed at the repo root, served from raw.githubusercontent.com; a Python generator (`scripts/make_appcast.py`, covered by the Linux pytest spec suite) emits/validates items, and `scripts/publish-release.sh` orders the release so an appcast enclosure can never 404.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14), Sparkle 2 (SPM), XCTest, XcodeGen, Python 3.11 + pytest + PyNaCl (appcast tooling), bash + gh CLI (pipeline).

## Global Constraints

- Working copy is `~/dev/murmur` (NOT the stale `~/Desktop/projects/murmur`). All paths below are relative to `~/dev/murmur`.
- Build needs full Xcode: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in every shell.
- After creating or deleting ANY Swift source file: `cd Pomvox && xcodegen generate` (the .xcodeproj is gitignored; project.yml globs `Sources/` and `Tests/`).
- Swift test command (fast, one class): `cd Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' -only-testing:PomvoxTests/<ClassName> 2>&1 | tail -20`
- Full Swift suite before each commit that touches Swift: same command without `-only-testing:`. Python suite: `uv run --frozen pytest -q` at repo root.
- Derived data ALWAYS at `/tmp/pomvox-dd` (never inside the repo).
- Swift tests import with `@testable import Pomvox` and must NOT `import Sparkle` (the seam design below makes that possible; CI runs with `CODE_SIGNING_ALLOWED=NO`).
- Commits: conventional commits (`feat(updater): …`), subject ≤ 72 chars, GPG signing is automatic, end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Spec contracts that MUST hold: **never a popup, never any stock Sparkle window** — Sparkle runs headless behind our `SPUUserDriver`; install happens **only on user click**; Debug builds are completely inert (no checks, no UI) unless `POMVOX_UPDATE_FEED` is set; production startup calls `clearFeedURLFromUserDefaults()`; relaunch waits for in-flight dictation; bundle ID `app.pomvox.hub` and team `CT84AT52RS` never change in an update (TCC continuity).
- Info.plist keys (exact values, from the spec): `SUFeedURL=https://raw.githubusercontent.com/abhiram304/pomvox/main/appcast.xml`, `SUPublicEDKey=<generated>`, `SUEnableAutomaticChecks=YES`, `SUAutomaticallyUpdate=NO`, `SUScheduledCheckInterval=86400`, `SUVerifyUpdateBeforeExtraction=YES`, `SUEnableJavaScript=NO`.
- Versioning: `sparkle:version` = `CURRENT_PROJECT_VERSION` (monotonic build number — MUST bump every release), `sparkle:shortVersionString` = `MARKETING_VERSION`. The updater ships in the next tagged release (v0.1.11); the first update *delivered through it* is v0.1.12.
- NEVER run `scripts/publish-release.sh`, `gh release create`, or push `appcast.xml` changes during implementation — releasing is a human step after the plan completes.
- New user-facing copy says **Pomvox** (never Murmur/Natter/Sparkle — the engine name is an implementation detail; error copy says "couldn't be verified", not "EdDSA failure").

---

### Task 1: Sparkle SPM package, tools fetcher, EdDSA keys, Info.plist keys

**Files:**
- Modify: `Pomvox/project.yml` (packages block ~line 12, Pomvox target deps ~line 86, new `info:` block under the Pomvox target)
- Create: `scripts/sparkle-tools.sh`
- Modify: `.gitignore` (add the generated `Pomvox/Info.plist`)

**Interfaces:**
- Consumes: nothing.
- Produces: the `Sparkle` module importable from app sources; `scripts/sparkle-tools.sh` prints the directory containing `generate_keys` / `sign_update` / `generate_appcast`; built app's Info.plist carries all seven SU keys; the EdDSA public key string (also needed by Task 7's verifier and Task 8).

- [ ] **Step 1: Pin the Sparkle version**

Run: `gh api repos/sparkle-project/Sparkle/releases/latest --jq .tag_name`
Expected: a `2.x.y` tag (the spec anticipated ~2.9.x). Use that exact version everywhere `<SPARKLE_VERSION>` appears below. If the latest is a pre-release or 3.x, pick the newest stable 2.x from `gh api repos/sparkle-project/Sparkle/releases --jq '.[].tag_name' | grep '^2\.' | head -5`.

- [ ] **Step 2: Create the tools fetcher**

Create `scripts/sparkle-tools.sh`:

```bash
#!/usr/bin/env bash
#
# sparkle-tools.sh — fetch (once, cached) the Sparkle command-line tools
# (generate_keys, sign_update, generate_appcast) and print their bin dir.
# The version MUST match the SPM pin in Pomvox/project.yml so signatures
# are produced by the same code that verifies them.
#
# Usage:  BIN="$(scripts/sparkle-tools.sh)" && "$BIN/sign_update" ...
set -euo pipefail

VERSION="${SPARKLE_TOOLS_VERSION:-<SPARKLE_VERSION>}"
CACHE="${SPARKLE_TOOLS_DIR:-$HOME/.cache/pomvox/sparkle-tools/$VERSION}"

if [ ! -x "$CACHE/bin/sign_update" ]; then
  mkdir -p "$CACHE"
  curl -fsSL -o "$CACHE/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  tar -xf "$CACHE/Sparkle.tar.xz" -C "$CACHE"
fi
[ -x "$CACHE/bin/sign_update" ] || { echo "sparkle tools missing after extract" >&2; exit 1; }
echo "$CACHE/bin"
```

Then: `chmod +x scripts/sparkle-tools.sh` and run it. Expected: prints the bin dir; `ls "$(scripts/sparkle-tools.sh)"` shows `generate_keys`, `sign_update`, `generate_appcast`. (If the tarball layout differs — tools at the archive root instead of `bin/` — adjust the two `bin/` references to match reality and re-run.)

- [ ] **Step 3: Generate the EdDSA keypair (ONE TIME — irreversible if lost)**

```bash
BIN="$(scripts/sparkle-tools.sh)"
"$BIN/generate_keys"
```

Expected: prints `SUPublicEDKey` XML/value and stores the private key in the login Keychain ("Private key for signing Sparkle updates"). If a key already exists it prints the existing public key — use that, do NOT regenerate. Record the base64 public key for Step 4.

**⚠️ STOP — human checkpoint.** Tell the user, in the task report, verbatim: *"The Sparkle EdDSA private key now lives in your login Keychain. Before any release: (1) export a backup with `"$BIN"/generate_keys -x ~/Desktop/pomvox-eddsa-private.key`, move it to offline storage (NOT iCloud), then delete the Desktop copy; (2) add the same exported key as a GitHub Actions secret named `SPARKLE_ED_PRIVATE_KEY` for future CI use. Losing this key strands every installed copy."* Do not perform the export/upload yourself.

- [ ] **Step 4: Add the package, dependency, and Info.plist keys to project.yml**

In `Pomvox/project.yml`, add to the `packages:` block:

```yaml
  # In-app updates (M8): Sparkle 2 headless — SPUUpdater + a custom user
  # driver; all UI is native (see docs/superpowers/specs/2026-07-09-in-app-updates-design.md).
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle.git
    from: "<SPARKLE_VERSION>"
```

Add to the Pomvox target's `dependencies:` list:

```yaml
      - package: Sparkle
```

Add to the Pomvox target (sibling of `settings:` and `dependencies:`):

```yaml
    info:
      path: Info.plist
      properties:
        # Sparkle (M8). SUPublicEDKey pairs with the private key in the
        # maintainer's Keychain; SUAutomaticallyUpdate NO = install only on
        # user click; SUVerifyUpdateBeforeExtraction = refuse bad signatures
        # before unpacking a byte.
        SUFeedURL: https://raw.githubusercontent.com/abhiram304/pomvox/main/appcast.xml
        SUPublicEDKey: <PASTE THE BASE64 PUBLIC KEY FROM STEP 3>
        SUEnableAutomaticChecks: true
        SUAutomaticallyUpdate: false
        SUScheduledCheckInterval: 86400
        SUVerifyUpdateBeforeExtraction: true
        SUEnableJavaScript: false
```

Add `Pomvox/Info.plist` to `.gitignore` (it is regenerated by `xcodegen generate`, like the .xcodeproj).

- [ ] **Step 5: Regenerate, build, and verify the plist merge**

```bash
cd Pomvox && xcodegen generate
xcodebuild build -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -3
PLIST=/tmp/pomvox-dd/Build/Products/Debug/Pomvox.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" -c "Print :SUPublicEDKey" -c "Print :SUScheduledCheckInterval" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" -c "Print :CFBundleIdentifier" "$PLIST"
```

Expected: BUILD SUCCEEDED; the SU keys print their values; the mic usage description AND `app.pomvox.hub` still print (proves xcodegen's `info:` file and the `INFOPLIST_KEY_*`/`GENERATE_INFOPLIST_FILE` build settings merged rather than clobbered). **If any INFOPLIST_KEY_-sourced value is missing:** set `GENERATE_INFOPLIST_FILE: NO` on the target and move every `INFOPLIST_KEY_<X>` value into `info.properties` as its plain key (e.g. `NSMicrophoneUsageDescription`), then repeat this step.

- [ ] **Step 6: Commit**

```bash
git add Pomvox/project.yml scripts/sparkle-tools.sh .gitignore
git commit -m "feat(updater): add Sparkle 2 SPM package, EdDSA keys, feed plist keys"
```

---

### Task 2: UpdaterState — the pure state machine

**Files:**
- Create: `Pomvox/Sources/UpdaterState.swift`
- Test: `Pomvox/Tests/UpdaterStateTests.swift`

**Interfaces:**
- Consumes: nothing (pure; no Sparkle import).
- Produces:
  `enum UpdaterState: Equatable { case idle, checking, updateAvailable(version: String, releaseNotesURL: URL?), downloading(fraction: Double?), extracting(fraction: Double?), readyToRelaunch, installing, upToDate, error(message: String) }`
  `enum UpdaterEvent: Equatable { case checkStarted, updateFound(version: String, releaseNotesURL: URL?), noUpdateFound, downloadStarted, downloadProgressed(fraction: Double?), extractionStarted, extractionProgressed(fraction: Double), readyToInstall, installStarted, dismissed, failed(message: String) }`
  `UpdaterState.reduce(_:_:) -> UpdaterState`, `var showsBanner: Bool`.

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/UpdaterStateTests.swift`:

```swift
import XCTest
@testable import Pomvox

final class UpdaterStateTests: XCTestCase {
    private let notes = URL(string: "https://github.com/abhiram304/pomvox/releases/tag/v0.1.12")!

    func testHappyPathReachesRelaunch() {
        var s = UpdaterState.idle
        let events: [UpdaterEvent] = [
            .checkStarted,
            .updateFound(version: "0.1.12", releaseNotesURL: notes),
            .downloadStarted,
            .downloadProgressed(fraction: 0.5),
            .extractionStarted,
            .extractionProgressed(fraction: 0.8),
            .readyToInstall,
            .installStarted,
        ]
        for e in events { s = UpdaterState.reduce(s, e) }
        XCTAssertEqual(s, .installing)
    }

    func testCheckWithNoUpdateIsUpToDate() {
        var s = UpdaterState.reduce(.idle, .checkStarted)
        XCTAssertEqual(s, .checking)
        s = UpdaterState.reduce(s, .noUpdateFound)
        XCTAssertEqual(s, .upToDate)
    }

    func testDismissedReturnsToIdleFromAnyBannerState() {
        let banner: [UpdaterState] = [
            .updateAvailable(version: "0.1.12", releaseNotesURL: nil),
            .downloading(fraction: 0.2), .extracting(fraction: nil),
            .readyToRelaunch, .installing,
        ]
        for s in banner {
            XCTAssertEqual(UpdaterState.reduce(s, .dismissed), .idle, "\(s)")
        }
    }

    func testFailureCarriesMessage() {
        let s = UpdaterState.reduce(.downloading(fraction: 0.9),
                                    .failed(message: "Update couldn't be verified"))
        XCTAssertEqual(s, .error(message: "Update couldn't be verified"))
    }

    func testDownloadProgressWithUnknownLength() {
        let s = UpdaterState.reduce(.downloading(fraction: nil),
                                    .downloadProgressed(fraction: nil))
        XCTAssertEqual(s, .downloading(fraction: nil))
    }

    func testShowsBannerExactlyForInFlightUpdateStates() {
        XCTAssertTrue(UpdaterState.updateAvailable(version: "1", releaseNotesURL: nil).showsBanner)
        XCTAssertTrue(UpdaterState.downloading(fraction: nil).showsBanner)
        XCTAssertTrue(UpdaterState.extracting(fraction: 0.1).showsBanner)
        XCTAssertTrue(UpdaterState.readyToRelaunch.showsBanner)
        XCTAssertTrue(UpdaterState.installing.showsBanner)
        XCTAssertFalse(UpdaterState.idle.showsBanner)
        XCTAssertFalse(UpdaterState.checking.showsBanner)
        XCTAssertFalse(UpdaterState.upToDate.showsBanner)
        XCTAssertFalse(UpdaterState.error(message: "x").showsBanner)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Pomvox && xcodegen generate && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' -only-testing:PomvoxTests/UpdaterStateTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'UpdaterState' in scope`.

- [ ] **Step 3: Implement the reducer**

Create `Pomvox/Sources/UpdaterState.swift`:

```swift
import Foundation

/// The one state the whole update UI renders from. `UpdaterModel` reduces
/// Sparkle user-driver callbacks into these events; the reducer is pure so
/// the machine is unit-testable with no Sparkle and no network.
enum UpdaterState: Equatable {
    case idle
    case checking
    case updateAvailable(version: String, releaseNotesURL: URL?)
    case downloading(fraction: Double?)   // nil until a content length is known
    case extracting(fraction: Double?)
    case readyToRelaunch
    case installing
    case upToDate
    case error(message: String)
}

enum UpdaterEvent: Equatable {
    case checkStarted
    case updateFound(version: String, releaseNotesURL: URL?)
    case noUpdateFound
    case downloadStarted
    case downloadProgressed(fraction: Double?)
    case extractionStarted
    case extractionProgressed(fraction: Double)
    case readyToInstall
    case installStarted
    case dismissed
    case failed(message: String)
}

extension UpdaterState {
    /// Sparkle sequences its callbacks; each event fully determines the next
    /// state, so this is a mapping rather than a guard table.
    static func reduce(_ state: UpdaterState, _ event: UpdaterEvent) -> UpdaterState {
        switch event {
        case .checkStarted:                return .checking
        case let .updateFound(v, url):     return .updateAvailable(version: v, releaseNotesURL: url)
        case .noUpdateFound:               return .upToDate
        case .downloadStarted:             return .downloading(fraction: nil)
        case let .downloadProgressed(f):   return .downloading(fraction: f)
        case .extractionStarted:           return .extracting(fraction: nil)
        case let .extractionProgressed(f): return .extracting(fraction: f)
        case .readyToInstall:              return .readyToRelaunch
        case .installStarted:              return .installing
        case .dismissed:                   return .idle
        case let .failed(m):               return .error(message: m)
        }
    }

    /// The Home banner shows for everything between "found" and relaunch —
    /// and for nothing else (checking and up-to-date stay quiet on Home).
    var showsBanner: Bool {
        switch self {
        case .updateAvailable, .downloading, .extracting, .readyToRelaunch, .installing:
            return true
        case .idle, .checking, .upToDate, .error:
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Pomvox/Sources/UpdaterState.swift Pomvox/Tests/UpdaterStateTests.swift
git commit -m "feat(updater): pure UpdaterState reducer + banner predicate"
```

---

### Task 3: UpdaterModel — headless Sparkle driver, feed override, relaunch gate

**Files:**
- Create: `Pomvox/Sources/UpdaterModel.swift`
- Test: `Pomvox/Tests/UpdaterModelTests.swift`

**Interfaces:**
- Consumes: `UpdaterState`/`UpdaterEvent` (Task 2); `Sparkle` module (Task 1).
- Produces (used by Tasks 4–6):
  `enum UpdateChoice { case install, dismiss, skip }` (our type — tests and UI never import Sparkle),
  `final class UpdaterModel: NSObject, ObservableObject` with `static let shared`, `@Published private(set) var state: UpdaterState`, `@Published private(set) var lastCheckDate: Date?`, `var isDictationBusy: () -> Bool`, `var relaunchPollInterval: TimeInterval`, `static var isEnabled: Bool`, `static func feedOverride(env:) -> String?`, `var automaticallyChecksForUpdates: Bool` (get/set), `func start()`, `func checkNow()`, `func install()`, `func later()`, `func skip()`, internal seams `apply(_:)`, `handleUpdateFound(version:notesURL:reply:)`, `handleReadyToRelaunch(reply:)`, `noteCheckCompleted(date:)`, `static func lastCheckedLabel(_:now:) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/UpdaterModelTests.swift` (note: no `import Sparkle` — everything goes through the internal seams and `UpdateChoice`):

```swift
import XCTest
@testable import Pomvox

final class UpdaterModelTests: XCTestCase {

    func testFeedOverrideReadsEnvVar() {
        XCTAssertEqual(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "http://localhost:8000/a.xml"]),
                       "http://localhost:8000/a.xml")
        XCTAssertNil(UpdaterModel.feedOverride(env: [:]))
    }

    func testDriverEventsDrivePublishedState() {
        let m = UpdaterModel()
        m.apply(.checkStarted)
        XCTAssertEqual(m.state, .checking)
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { _ in }
        XCTAssertEqual(m.state, .updateAvailable(version: "0.1.12", releaseNotesURL: nil))
    }

    func testInstallRepliesInstallAndOnlyOnce() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.install()
        m.install()   // second click must not double-reply
        XCTAssertEqual(replies, [.install])
    }

    func testLaterDismissesBannerAndRepliesDismiss() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.later()
        XCTAssertEqual(replies, [.dismiss])
        XCTAssertEqual(m.state, .idle)
    }

    func testSkipRepliesSkip() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.skip()
        XCTAssertEqual(replies, [.skip])
        XCTAssertEqual(m.state, .idle)
    }

    func testRelaunchWaitsForInFlightDictation() {
        let m = UpdaterModel()
        m.relaunchPollInterval = 0.01
        var busyPolls = 0
        m.isDictationBusy = { busyPolls += 1; return busyPolls < 3 }  // busy twice, then idle
        let done = expectation(description: "reply sent after dictation ends")
        m.handleReadyToRelaunch { choice in
            XCTAssertEqual(choice, .install)
            done.fulfill()
        }
        XCTAssertEqual(m.state, .readyToRelaunch)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(m.state, .installing)
        XCTAssertGreaterThanOrEqual(busyPolls, 3)
    }

    func testRelaunchImmediateWhenIdle() {
        let m = UpdaterModel()
        var replied: UpdateChoice?
        m.isDictationBusy = { false }
        m.handleReadyToRelaunch { replied = $0 }
        XCTAssertEqual(replied, .install)
        XCTAssertEqual(m.state, .installing)
    }

    func testLastCheckedLabel() {
        XCTAssertEqual(UpdaterModel.lastCheckedLabel(nil), "Never checked")
        let label = UpdaterModel.lastCheckedLabel(Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(label.hasPrefix("Last checked"), label)
    }

    func testFriendlyMessageMapsTranslocationAndVerification() {
        let transloc = NSError(domain: "SUSparkleErrorDomain", code: 1, userInfo:
            [NSLocalizedDescriptionKey: "The update will not be installed because the application is translocated"])
        XCTAssertEqual(UpdaterModel.friendlyMessage(for: transloc),
                       "Move Pomvox to the Applications folder to enable updates.")
        let badSig = NSError(domain: "SUSparkleErrorDomain", code: 2, userInfo:
            [NSLocalizedDescriptionKey: "The update archive failed signature validation"])
        XCTAssertTrue(UpdaterModel.friendlyMessage(for: badSig).contains("couldn't be verified"))
        let offline = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo:
            [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        XCTAssertEqual(UpdaterModel.friendlyMessage(for: offline),
                       "The Internet connection appears to be offline.")
    }

    func testScheduledCheckErrorIsSilentButManualCheckErrorShows() {
        let m = UpdaterModel()
        let err = NSError(domain: "x", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "offline"])
        m.showUpdaterError(err) {}          // scheduled path: silent, back to idle
        XCTAssertEqual(m.state, .idle)
        m.checkNow()                        // marks the next cycle user-initiated
        m.showUpdaterError(err) {}
        XCTAssertEqual(m.state, .error(message: "offline"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Pomvox && xcodegen generate && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' -only-testing:PomvoxTests/UpdaterModelTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'UpdaterModel' in scope`.

- [ ] **Step 3: Implement UpdaterModel**

Create `Pomvox/Sources/UpdaterModel.swift`. Two halves: the model (Sparkle-free seams, fully covered by the tests above) and the Sparkle conformances (thin forwarding, exercised by the Task 9 rehearsal).

```swift
import Foundation
import os
import Sparkle

/// Our own copy of Sparkle's user choice so tests and UI never import Sparkle.
enum UpdateChoice: Equatable { case install, dismiss, skip }

/// Headless Sparkle: owns the SPUUpdater, maps every SPUUserDriver callback
/// onto the pure UpdaterState reducer, and exposes the user actions the Home
/// banner and Settings render. Sparkle never shows a window of its own.
final class UpdaterModel: NSObject, ObservableObject {
    static let shared = UpdaterModel()

    @Published private(set) var state: UpdaterState = .idle
    @Published private(set) var lastCheckDate: Date?

    /// Wired to the engine at app startup (Task 4); tests inject their own.
    var isDictationBusy: () -> Bool = { false }
    /// Poll cadence while waiting out an in-flight dictation before relaunch.
    var relaunchPollInterval: TimeInterval = 0.5

    private let log = Logger(subsystem: "app.pomvox.hub", category: "updater")
    private var updater: SPUUpdater?
    private var updateReply: ((UpdateChoice) -> Void)?
    private var userInitiatedCheck = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    /// Release builds: always on. Debug builds: only with POMVOX_UPDATE_FEED
    /// set (state-machine debugging) — otherwise fully inert: no scheduled
    /// checks, no UI surfaces, `start()` is a no-op.
    static var isEnabled: Bool {
        #if DEBUG
        return feedOverride() != nil
        #else
        return true
        #endif
    }

    static func feedOverride(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        env["POMVOX_UPDATE_FEED"]
    }

    /// Maps straight onto Sparkle's persisted setting (SUEnableAutomaticChecks
    /// in defaults). Defaults to true before start() — the Info.plist default.
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set {
            objectWillChange.send()
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    func start() {
        guard Self.isEnabled, updater == nil else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                           userDriver: self, delegate: self)
        // Hardening (Sparkle-documented): a feed URL persisted into defaults
        // must never override the Info.plist feed in production.
        u.clearFeedURLFromUserDefaults()
        do {
            try u.start()
        } catch {
            apply(.failed(message: error.localizedDescription))
            return
        }
        updater = u
        lastCheckDate = u.lastUpdateCheckDate
    }

    func checkNow() {
        userInitiatedCheck = true
        updater?.checkForUpdates()
    }

    // MARK: - user actions (Home banner / Settings)

    func install() { respond(.install) }
    func later()   { respond(.dismiss); apply(.dismissed) }
    func skip()    { respond(.skip);    apply(.dismissed) }

    private func respond(_ choice: UpdateChoice) {
        updateReply?(choice)
        updateReply = nil
    }

    // MARK: - reducer seams (internal: tests drive these without Sparkle)

    func apply(_ event: UpdaterEvent) {
        state = UpdaterState.reduce(state, event)
    }

    func handleUpdateFound(version: String, notesURL: URL?,
                           reply: @escaping (UpdateChoice) -> Void) {
        updateReply = reply
        apply(.updateFound(version: version, releaseNotesURL: notesURL))
    }

    /// Sparkle is ready to swap bundles and relaunch. The user already clicked
    /// Update — the only thing worth waiting for is an in-flight dictation.
    func handleReadyToRelaunch(reply: @escaping (UpdateChoice) -> Void) {
        apply(.readyToInstall)
        guard isDictationBusy() else {
            apply(.installStarted)
            reply(.install)
            return
        }
        Timer.scheduledTimer(withTimeInterval: relaunchPollInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !self.isDictationBusy() {
                timer.invalidate()
                self.apply(.installStarted)
                reply(.install)
            }
        }
    }

    func noteCheckCompleted(date: Date = Date()) {
        lastCheckDate = date
    }

    static func lastCheckedLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never checked" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last checked \(f.localizedString(for: date, relativeTo: now))"
    }

    /// Spec error contract: plain-language copy, never Sparkle jargon.
    static func friendlyMessage(for error: NSError) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("transloc") || lower.contains("quarantine") {
            return "Move Pomvox to the Applications folder to enable updates."
        }
        if lower.contains("signature") || lower.contains("validat") || lower.contains("verif") {
            return "The update couldn't be verified. Download it manually from the releases page."
        }
        return raw
    }
}

// MARK: - Sparkle user driver (thin forwarding; no logic beyond mapping)
//
// NOTE: verify these method signatures against the pinned Sparkle version —
// if the compiler reports missing/renamed requirements, use Xcode's
// "add protocol stubs" fix-it and keep each body a one-line forward onto the
// seams above. The logic lives (tested) in the seams, not here.

extension UpdaterModel: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Never show Sparkle's permission prompt: checks are on by default,
        // no system profile — disclosed in Settings and README instead.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiatedCheck = true
        apply(.checkStarted)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleUpdateFound(version: appcastItem.displayVersionString,
                          notesURL: appcastItem.releaseNotesURL ?? appcastItem.infoURL) { choice in
            switch choice {
            case .install: reply(.install)
            case .dismiss: reply(.dismiss)
            case .skip:    reply(.skip)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}          // we link out
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}     // to GitHub

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        apply(.noUpdateFound)
        noteCheckCompleted()
        userInitiatedCheck = false
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Spec error contract: a failed SCHEDULED check stays silent (log +
        // retry next interval); a failed manual check or in-flight install
        // renders inline. Never a popup either way.
        if userInitiatedCheck || state.showsBanner {
            apply(.failed(message: Self.friendlyMessage(for: error as NSError)))
        } else {
            log.error("scheduled update check failed: \(error.localizedDescription, privacy: .public)")
            apply(.dismissed)
        }
        userInitiatedCheck = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        apply(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        let fraction = expectedLength > 0
            ? min(Double(receivedLength) / Double(expectedLength), 1.0) : nil
        apply(.downloadProgressed(fraction: fraction))
    }

    func showDownloadDidStartExtractingUpdate() {
        apply(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        apply(.extractionProgressed(fraction: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleReadyToRelaunch { choice in
            reply(choice == .install ? .install : .dismiss)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        apply(.installStarted)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // End of a Sparkle session. Keep an unactioned banner and any error
        // visible; clear only transient states (checking / upToDate).
        switch state {
        case .checking, .upToDate: apply(.dismissed)
        default: break
        }
    }
}

// MARK: - Sparkle updater delegate

extension UpdaterModel: SPUUpdaterDelegate {
    /// Test/rig override: POMVOX_UPDATE_FEED wins; nil falls back to the
    /// Info.plist SUFeedURL (production path).
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        DispatchQueue.main.async { self.noteCheckCompleted() }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS (10 tests). If the SPUUserDriver conformance fails to compile against the pinned Sparkle version, fix the extension's signatures per the compiler (the seams and tests must not change).

- [ ] **Step 5: Run the full Swift suite**

Run: `cd Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -5`
Expected: all green (no regressions from the new package).

- [ ] **Step 6: Commit**

```bash
git add Pomvox/Sources/UpdaterModel.swift Pomvox/Tests/UpdaterModelTests.swift
git commit -m "feat(updater): headless UpdaterModel — Sparkle driver, feed override, relaunch gate"
```

---

### Task 4: App wiring + Debug inertness

**Files:**
- Modify: `Pomvox/Sources/PomvoxApp.swift`
- Modify: `Pomvox/Sources/AppDelegate.swift`

**Interfaces:**
- Consumes: `UpdaterModel.shared`, `UpdaterModel.isEnabled` (Task 3); `NativeEngine.shared.status` (existing: `.recording` / `.transcribing` cases mean busy).
- Produces: `UpdaterModel` available as an `@EnvironmentObject` to all views (Tasks 5–6); updater started exactly once at launch, engine-busy closure wired.

- [ ] **Step 1: Inject the model in PomvoxApp**

In `Pomvox/Sources/PomvoxApp.swift`, add alongside the other `@StateObject`s (same `.shared` pattern as `NativeEngine`):

```swift
    @StateObject private var updater = UpdaterModel.shared
```

and add to the `RootView()` modifier chain, with the other `.environmentObject(...)` lines:

```swift
                .environmentObject(updater)
```

- [ ] **Step 2: Start the updater in AppDelegate**

The Hub window stays closed on login-item launches, so startup wiring must NOT hang off a view's `onAppear`. Read `Pomvox/Sources/AppDelegate.swift`, find `applicationDidFinishLaunching` (create the method if absent, matching the file's style), and append:

```swift
        // In-app updates (M8): headless Sparkle. Inert in Debug builds unless
        // POMVOX_UPDATE_FEED is set. Relaunch defers to an in-flight dictation.
        UpdaterModel.shared.isDictationBusy = {
            switch NativeEngine.shared.status {
            case .recording, .transcribing: return true
            default: return false
            }
        }
        UpdaterModel.shared.start()
```

If `NativeEngine.status` access requires main-actor isolation here, wrap the closure body in `MainActor.assumeIsolated { ... }` — Sparkle drives the user driver on the main thread.

- [ ] **Step 3: Build and verify Debug inertness**

```bash
cd Pomvox && xcodebuild build -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

Manual check (do it — the on-device verification playbook applies): launch the Debug build, then
`/usr/bin/log stream --predicate 'process == "Pomvox"' --info 2>&1 | grep -i -E "sparkle|appcast|update" &` for ~30 s.
Expected: **zero** updater/Sparkle activity (Debug + no env var ⇒ `start()` no-ops). Kill the app and the log stream.

- [ ] **Step 4: Run the full Swift suite**

Run: `cd Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Pomvox/Sources/PomvoxApp.swift Pomvox/Sources/AppDelegate.swift
git commit -m "feat(updater): wire UpdaterModel at launch; Debug builds stay inert"
```

---

### Task 5: Home banner

**Files:**
- Create: `Pomvox/Sources/UpdateBanner.swift`
- Modify: `Pomvox/Sources/HomeView.swift` (insert into the ScrollView's VStack, before the `greeting` line)

**Interfaces:**
- Consumes: `UpdaterModel` environment object (`state`, `install()`, `later()`, `skip()`); `UpdaterState.showsBanner`; existing `Palette` / `Typo` design tokens.
- Produces: `struct UpdateBanner: View` — renders nothing unless `state.showsBanner`.

- [ ] **Step 1: Create the banner view**

Create `Pomvox/Sources/UpdateBanner.swift`:

```swift
import SwiftUI

/// The quiet, native update affordance on Home. Renders only while an update
/// session is in a banner state — never a popup, never a Sparkle window.
struct UpdateBanner: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        if updater.state.showsBanner {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17)).foregroundStyle(Palette.ember)
                content
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case let .updateAvailable(version, notesURL):
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available — v\(version)")
                    .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
                if let notesURL {
                    Link("Release notes", destination: notesURL)
                        .font(Typo.ui(12)).foregroundStyle(Palette.ember)
                }
            }
        case let .downloading(fraction):
            progressLine("Downloading update…", fraction: fraction)
        case let .extracting(fraction):
            progressLine("Preparing update…", fraction: fraction)
        case .readyToRelaunch:
            Text("Finishing your dictation, then restarting…")
                .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
        case .installing:
            Text("Restarting to finish the update…")
                .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        if case .updateAvailable = updater.state {
            HStack(spacing: 10) {
                Button("Skip this version") { updater.skip() }
                    .buttonStyle(.plain)
                    .font(Typo.ui(12)).foregroundStyle(Palette.muted)
                Button("Later") { updater.later() }
                    .buttonStyle(.plain)
                    .font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
                Button { updater.install() } label: {
                    Text("Update")
                        .font(Typo.ui(12.5, .semibold)).foregroundStyle(Palette.pane)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Palette.ember))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func progressLine(_ label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
            if let fraction {
                ProgressView(value: fraction).tint(Palette.ember).frame(maxWidth: 260)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
```

(If `Palette.pane` doesn't exist as the light-on-ember text color, check `DesignSystem.swift` for the token the app uses for text on ember-filled controls and use that instead — match the existing quick-add / primary-button styling.)

- [ ] **Step 2: Insert into HomeView**

In `Pomvox/Sources/HomeView.swift`, inside `ScrollView { VStack(alignment: .leading, spacing: 0) { ... } }`, add as the FIRST child (before `greeting.padding(.bottom, 26)`) so it shows in both the empty and populated states:

```swift
                    UpdateBanner().padding(.bottom, 20)
```

- [ ] **Step 3: Build + full suite**

Run: `cd Pomvox && xcodegen generate && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED, all tests green (the banner renders `EmptyView` in every test/default state; `UpdaterState.showsBanner` is already covered by Task 2's tests).

- [ ] **Step 4: Commit**

```bash
git add Pomvox/Sources/UpdateBanner.swift Pomvox/Sources/HomeView.swift
git commit -m "feat(updater): native Home banner — update/later/skip, inline progress"
```

---

### Task 6: Settings ▸ General — Updates group

**Files:**
- Modify: `Pomvox/Sources/SettingsView.swift` (new `private struct UpdatesGroup` + insertion into `GeneralPane`, which starts ~line 116)

**Interfaces:**
- Consumes: `UpdaterModel` environment object (`state`, `lastCheckDate`, `automaticallyChecksForUpdates`, `checkNow()`, `UpdaterModel.lastCheckedLabel`, `UpdaterModel.isEnabled`); the file's existing private components `SettingsGroup`, `SettingRow`, `SettingToggle`, `InfoRow`, `RowDivider`.
- Produces: the Updates group in Settings ▸ General; hidden entirely when `UpdaterModel.isEnabled` is false (Debug without the env override).

- [ ] **Step 1: Add UpdatesGroup**

In `Pomvox/Sources/SettingsView.swift`, add near the other pane groups (after `LoginItemGroup`'s definition):

```swift
// MARK: - updates (M8)

private struct UpdatesGroup: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        SettingsGroup("Updates") {
            SettingRow(title: "Automatically check for updates",
                       desc: "Once a day, Pomvox fetches a public version file from GitHub. "
                           + "Nothing about you or your dictations is sent.") {
                SettingToggle(isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
            }
            RowDivider()
            SettingRow(title: "Check for updates",
                       desc: UpdaterModel.lastCheckedLabel(updater.lastCheckDate)) {
                Button("Check Now") { updater.checkNow() }
                    .disabled(updater.state == .checking)
            }
            if let status = statusLine {
                RowDivider()
                InfoRow(symbol: statusSymbol, text: status)
            }
            if case .error = updater.state {
                // Spec error contract: a failed/unverifiable update always
                // leaves a manual path open.
                RowDivider()
                SettingRow(title: "Download manually",
                           desc: "Get the latest release from GitHub.") {
                    Link("Releases", destination:
                        URL(string: "https://github.com/abhiram304/pomvox/releases")!)
                }
            }
            RowDivider()
            InfoRow(symbol: "app.badge", text: Bundle.main.pomvoxVersionLabel)
        }
    }

    /// Inline feedback for a manual check — never a popup.
    private var statusLine: String? {
        switch updater.state {
        case .checking:            "Checking…"
        case .upToDate:            "You're up to date."
        case let .error(message):  message
        default:                   nil
        }
    }

    private var statusSymbol: String {
        if case .error = updater.state { "exclamationmark.triangle.fill" }
        else { "checkmark.circle" }
    }
}

extension Bundle {
    /// "Pomvox 0.1.11 (9)" — marketing version + monotonic build.
    var pomvoxVersionLabel: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Pomvox \(v) (\(b))"
    }
}
```

(First read the file's `GeneralPane` and match how `Button` styling is done elsewhere in the panes — use the same button style for "Check Now" as neighboring pane buttons, e.g. the bordered style used by the storage/wipe controls, rather than inventing a new one.)

- [ ] **Step 2: Insert into GeneralPane, gated on isEnabled**

Read `GeneralPane` (~lines 116–170) and add, after the last existing group in its layout (after `LoginItemGroup()`):

```swift
            if UpdaterModel.isEnabled {
                UpdatesGroup()
            }
```

- [ ] **Step 3: Write the failing test for the version label** (the only pure logic here)

Append to `Pomvox/Tests/UpdaterModelTests.swift`:

```swift
    func testPomvoxVersionLabelHasVersionAndBuild() {
        // Test bundle → falls back to its own plist values; shape is what matters.
        let label = Bundle.main.pomvoxVersionLabel
        XCTAssertTrue(label.hasPrefix("Pomvox "), label)
        XCTAssertTrue(label.contains("("), label)
    }
```

- [ ] **Step 4: Run tests**

Run: `cd Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' -only-testing:PomvoxTests/UpdaterModelTests 2>&1 | tail -10`
Expected: PASS (11 tests).

- [ ] **Step 5: Full suite + commit**

Run the full Swift suite (expect green), then:

```bash
git add Pomvox/Sources/SettingsView.swift Pomvox/Tests/UpdaterModelTests.swift
git commit -m "feat(updater): Settings Updates group — toggle, check now, last-checked, version"
```

---

### Task 7: appcast.xml + make_appcast.py (Python spec suite)

**Files:**
- Create: `appcast.xml` (repo root)
- Create: `scripts/make_appcast.py`
- Test: `tests/test_make_appcast.py`
- Modify: `pyproject.toml` (`dev` dependency group: add `pynacl`), `uv.lock` (via `uv lock`)

**Interfaces:**
- Consumes: nothing from the Swift side.
- Produces (used by Task 8's shell pipeline):
  `enclosure_url(tag: str, asset: str = "Pomvox.zip") -> str`,
  `appcast_item(short_version: str, build: int, tag: str, length: int, ed_signature: str, pub_date: datetime | None = None, min_system: str = "14.0") -> str`,
  `insert_item(appcast_text: str, item_text: str) -> str` (newest first; raises `ValueError` on duplicate build),
  `validate(appcast_text: str) -> list[str]` (empty list = valid),
  `verify_signature(path: str, ed_signature_b64: str, public_key_b64: str) -> bool`,
  CLI: `python3 scripts/make_appcast.py --appcast appcast.xml --zip dist/Pomvox.zip --tag vX.Y.Z --short-version X.Y.Z --build N --signature <b64> [--write]` (prints the updated XML; `--write` saves it in place; exits non-zero if `validate` fails).

- [ ] **Step 1: Commit the initial (empty, valid) appcast**

Create `appcast.xml` at the repo root:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkle-project.org/xml/rss/1.0/modules/sparkle">
  <channel>
    <title>Pomvox</title>
    <link>https://github.com/abhiram304/pomvox</link>
    <description>Pomvox release feed</description>
    <language>en</language>
  </channel>
</rss>
```

(An empty channel is a valid feed: pre-release "Check Now" resolves to "You're up to date" instead of a 404.)

- [ ] **Step 2: Add pynacl and write the failing tests**

In `pyproject.toml`, change the dev group to `dev = ["pytest", "pynacl"]`, then run `uv lock` (CI uses `--frozen`; the lockfile must be committed).

Create `tests/test_make_appcast.py`:

```python
"""Spec for scripts/make_appcast.py — the Sparkle appcast generator.

The appcast is the update feed committed at the repo root and served from
raw.githubusercontent.com. Items must be newest-first, carry an EdDSA
signature, and point at GitHub release assets that already exist.
"""
import base64
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import make_appcast as m

EMPTY = (Path(__file__).resolve().parent.parent / "appcast.xml").read_text()


def make_item(build=9, short="0.1.11", sig="c2ln"):
    return m.appcast_item(short_version=short, build=build, tag=f"v{short}",
                          length=12345, ed_signature=sig,
                          pub_date=datetime(2026, 7, 15, tzinfo=timezone.utc))


def test_enclosure_url():
    assert m.enclosure_url("v0.1.11") == \
        "https://github.com/abhiram304/pomvox/releases/download/v0.1.11/Pomvox.zip"


def test_item_carries_versions_signature_and_min_system():
    item = make_item()
    assert "<sparkle:version>9</sparkle:version>" in item
    assert "<sparkle:shortVersionString>0.1.11</sparkle:shortVersionString>" in item
    assert "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" in item
    assert 'sparkle:edSignature="c2ln"' in item
    assert 'length="12345"' in item
    assert "releases/tag/v0.1.11" in item        # release-notes link


def test_insert_into_empty_feed_validates():
    out = m.insert_item(EMPTY, make_item())
    assert m.validate(out) == []
    assert out.count("<item>") == 1


def test_insert_is_newest_first():
    one = m.insert_item(EMPTY, make_item(build=9, short="0.1.11"))
    two = m.insert_item(one, make_item(build=10, short="0.1.12"))
    assert m.validate(two) == []
    assert two.index("0.1.12") < two.index("0.1.11")


def test_duplicate_build_rejected():
    one = m.insert_item(EMPTY, make_item(build=9))
    with pytest.raises(ValueError):
        m.insert_item(one, make_item(build=9, short="0.1.11b"))


def test_inserting_older_build_rejected():
    # Downgrade trap: a new item must be strictly newer than everything shipped.
    one = m.insert_item(EMPTY, make_item(build=10, short="0.1.12"))
    with pytest.raises(ValueError):
        m.insert_item(one, make_item(build=9, short="0.1.11"))


def test_out_of_order_feed_fails_validation():
    # Simulate a hand-edited feed whose order went bad after the fact.
    one = m.insert_item(EMPTY, make_item(build=9, short="0.1.11"))
    two = m.insert_item(one, make_item(build=10, short="0.1.12"))
    broken = two.replace("<sparkle:version>10</sparkle:version>",
                         "<sparkle:version>8</sparkle:version>")
    assert m.validate(broken) != []


def test_validate_rejects_malformed_xml_and_missing_signature():
    assert m.validate("<rss>not closed") != []
    unsigned = m.insert_item(EMPTY, make_item()).replace(' sparkle:edSignature="c2ln"', "")
    assert m.validate(unsigned) != []


def test_verify_signature_roundtrip(tmp_path):
    nacl = pytest.importorskip("nacl.signing")
    payload = tmp_path / "Pomvox.zip"
    payload.write_bytes(b"not really a zip but bytes are bytes")
    key = nacl.SigningKey.generate()
    sig = key.sign(payload.read_bytes()).signature
    pub = key.verify_key.encode()
    assert m.verify_signature(str(payload), base64.b64encode(sig).decode(),
                              base64.b64encode(pub).decode())
    assert not m.verify_signature(str(payload), base64.b64encode(b"x" * 64).decode(),
                                  base64.b64encode(pub).decode())
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `uv run --frozen pytest tests/test_make_appcast.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'make_appcast'`.

- [ ] **Step 4: Implement make_appcast.py**

Create `scripts/make_appcast.py`:

```python
#!/usr/bin/env python3
"""Emit, splice, and validate Sparkle appcast items for Pomvox releases.

Used by scripts/publish-release.sh. Signing itself happens with Sparkle's
sign_update (Keychain); this script only assembles and checks XML, so the
Linux CI spec suite can cover it. sparkle:version is the monotonic build
number (CURRENT_PROJECT_VERSION); sparkle:shortVersionString is the
marketing version (MARKETING_VERSION).
"""
from __future__ import annotations

import argparse
import base64
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.etree import ElementTree

SPARKLE_NS = "http://www.sparkle-project.org/xml/rss/1.0/modules/sparkle"
REPO = "abhiram304/pomvox"


def enclosure_url(tag: str, asset: str = "Pomvox.zip") -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{asset}"


def appcast_item(short_version: str, build: int, tag: str, length: int,
                 ed_signature: str, pub_date: datetime | None = None,
                 min_system: str = "14.0") -> str:
    pub = format_datetime(pub_date or datetime.now(timezone.utc))
    return f"""    <item>
      <title>Version {short_version}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/{REPO}/releases/tag/{tag}</sparkle:releaseNotesLink>
      <enclosure url="{enclosure_url(tag)}" length="{length}"
                 type="application/octet-stream" sparkle:edSignature="{ed_signature}"/>
    </item>"""


def _builds(appcast_text: str) -> list[int]:
    return [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>",
                                       appcast_text)]


def insert_item(appcast_text: str, item_text: str) -> str:
    """Splice the item in newest-first (as the first <item>). Text surgery on
    purpose: ElementTree would rewrite namespace prefixes across the whole
    committed file; validate() re-parses the result for real."""
    new_builds = _builds(item_text)
    if len(new_builds) != 1:
        raise ValueError("item must carry exactly one sparkle:version")
    existing = _builds(appcast_text)
    if existing and new_builds[0] <= max(existing):
        raise ValueError(
            f"build {new_builds[0]} must be newer than the newest shipped build "
            f"({max(existing)}) — duplicates and downgrades are refused")
    if "<item>" in appcast_text:
        return appcast_text.replace("    <item>", item_text + "\n    <item>", 1)
    return appcast_text.replace("</channel>", item_text + "\n  </channel>", 1)


def validate(appcast_text: str) -> list[str]:
    """Return a list of problems; [] means the feed is publishable."""
    problems: list[str] = []
    try:
        root = ElementTree.fromstring(appcast_text)
    except ElementTree.ParseError as e:
        return [f"malformed XML: {e}"]
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        return ["not an rss feed with a channel"]
    ns = {"sparkle": SPARKLE_NS}
    builds: list[int] = []
    for item in channel.findall("item"):
        version = item.find("sparkle:version", ns)
        if version is None or not (version.text or "").isdigit():
            problems.append("item missing integer sparkle:version")
            continue
        builds.append(int(version.text))
        enclosure = item.find("enclosure")
        if enclosure is None:
            problems.append(f"build {version.text}: missing enclosure")
            continue
        url = enclosure.get("url", "")
        if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
            problems.append(f"build {version.text}: enclosure url {url!r} is not a release asset")
        if not enclosure.get("length", "").isdigit():
            problems.append(f"build {version.text}: enclosure length missing")
        if not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
            problems.append(f"build {version.text}: enclosure missing sparkle:edSignature")
    if builds != sorted(builds, reverse=True):
        problems.append(f"items are not newest-first by sparkle:version: {builds}")
    if len(set(builds)) != len(builds):
        problems.append(f"duplicate sparkle:version values: {builds}")
    return problems


def verify_signature(path: str, ed_signature_b64: str, public_key_b64: str) -> bool:
    """EdDSA-verify a release archive against SUPublicEDKey (pre-commit gate)."""
    from nacl.exceptions import BadSignatureError
    from nacl.signing import VerifyKey
    try:
        VerifyKey(base64.b64decode(public_key_b64)).verify(
            open(path, "rb").read(), base64.b64decode(ed_signature_b64))
        return True
    except (BadSignatureError, ValueError):
        return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--appcast", default="appcast.xml")
    p.add_argument("--zip", required=True, help="release archive (for its byte length)")
    p.add_argument("--tag", required=True)
    p.add_argument("--short-version", required=True)
    p.add_argument("--build", type=int, required=True)
    p.add_argument("--signature", required=True, help="base64 EdDSA signature from sign_update")
    p.add_argument("--write", action="store_true", help="update --appcast in place")
    args = p.parse_args()

    from pathlib import Path
    length = Path(args.zip).stat().st_size
    item = appcast_item(args.short_version, args.build, args.tag, length, args.signature)
    updated = insert_item(Path(args.appcast).read_text(), item)
    problems = validate(updated)
    if problems:
        for problem in problems:
            print(f"appcast INVALID: {problem}", file=sys.stderr)
        return 1
    if args.write:
        Path(args.appcast).write_text(updated)
    else:
        print(updated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `uv run --frozen pytest tests/test_make_appcast.py -q`
Expected: PASS (10 tests). Then the whole Python suite: `uv run --frozen pytest -q` — all green.

- [ ] **Step 6: Commit**

```bash
git add appcast.xml scripts/make_appcast.py tests/test_make_appcast.py pyproject.toml uv.lock
git commit -m "feat(updater): appcast feed + tested generator/validator (make_appcast.py)"
```

---

### Task 8: publish-release.sh — the ordered release pipeline

**Files:**
- Create: `scripts/publish-release.sh`
- Modify: `scripts/notarize-release.sh` (final "Done" echo block only: point the maintainer at the next step)

**Interfaces:**
- Consumes: `dist/Pomvox.zip` + `dist/Pomvox.dmg` (from `notarize-release.sh`), `scripts/sparkle-tools.sh` (Task 1), `scripts/make_appcast.py` (Task 7), `SUPublicEDKey` in `Pomvox/project.yml`, `gh` CLI.
- Produces: a runnable, human-invoked release script enforcing the spec's ordering: **sign → create GitHub release with assets → confirm enclosure resolves → verify signature → only then commit appcast.xml**. Never run end-to-end during implementation; `--dry-run` is the testable path.

- [ ] **Step 1: Create the script**

Create `scripts/publish-release.sh`:

```bash
#!/usr/bin/env bash
#
# publish-release.sh — publish a Pomvox release WITH the Sparkle appcast, in
# the only safe order: no client may ever see an appcast entry whose
# enclosure 404s, so the GitHub release (with assets) goes out FIRST and the
# appcast commit to main goes out LAST.
#
#   1. Preconditions: clean main, dist artifacts present, versions coherent.
#   2. EdDSA-sign dist/Pomvox.zip (sign_update, key from login Keychain).
#   3. Splice + validate the appcast item (scripts/make_appcast.py).
#   4. gh release create vX.Y.Z with Pomvox.dmg + Pomvox.zip.
#   5. Poll the enclosure URL until it serves HTTP 200.
#   6. EdDSA-verify the zip against SUPublicEDKey (belt over braces).
#   7. Commit + push appcast.xml.
#   8. Print the Homebrew cask bump reminder.
#
# Usage:   scripts/publish-release.sh v0.1.11
#          scripts/publish-release.sh v0.1.11 --dry-run     # steps 1-3 + 6 only,
#                                                           # signs with SIGN_KEY_FILE
# Env:     SIGN_KEY_FILE  file-based EdDSA key for --dry-run (never for real
#                         releases — the real key lives in the Keychain)
#
# After this script: bump the Homebrew cask (abhiram304/homebrew-pomvox) —
#   version, sha256 (shasum -a 256 dist/Pomvox.dmg), plus ONCE:
#   `auto_updates true` and
#   `livecheck do; url "https://raw.githubusercontent.com/abhiram304/pomvox/main/appcast.xml"; strategy :sparkle; end`
#
# Release checklist reminders (from the design spec):
#   - MARKETING_VERSION and CURRENT_PROJECT_VERSION bumped in Pomvox/project.yml
#     BEFORE notarize-release.sh (sparkle:version = CURRENT_PROJECT_VERSION).
#   - Never rotate the Developer ID cert and the EdDSA key in the same release.
set -euo pipefail

TAG="${1:-}"; [ -n "$TAG" ] || { echo "usage: $0 vX.Y.Z [--dry-run]" >&2; exit 2; }
DRY_RUN="${2:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
ZIP="dist/Pomvox.zip"; DMG="dist/Pomvox.dmg"; APPCAST="appcast.xml"
SHORT="${TAG#v}"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

say "Preconditions"
[ "$(git branch --show-current)" = "main" ] || die "not on main"
git diff --quiet && git diff --cached --quiet || die "working tree not clean"
[ -f "$ZIP" ] && [ -f "$DMG" ] || die "dist artifacts missing — run scripts/notarize-release.sh first"
grep -q "MARKETING_VERSION: \"$SHORT\"" Pomvox/project.yml \
  || die "project.yml MARKETING_VERSION does not match $TAG"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' Pomvox/project.yml)"
[ -n "$BUILD" ] || die "could not read CURRENT_PROJECT_VERSION"
PUBKEY="$(sed -n 's/.*SUPublicEDKey: \(.*\)/\1/p' Pomvox/project.yml | tr -d ' "')"
[ -n "$PUBKEY" ] || die "could not read SUPublicEDKey from project.yml"
echo "  ✓ $TAG (marketing $SHORT, build $BUILD)"

say "EdDSA-signing $ZIP"
BIN="$(scripts/sparkle-tools.sh)"
if [ "$DRY_RUN" = "--dry-run" ] && [ -n "${SIGN_KEY_FILE:-}" ]; then
  SIGN_OUT="$("$BIN/sign_update" --ed-key-file "$SIGN_KEY_FILE" "$ZIP")"
else
  SIGN_OUT="$("$BIN/sign_update" "$ZIP")"   # key from login Keychain
fi
SIG="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
[ -n "$SIG" ] || die "sign_update produced no signature: $SIGN_OUT"
echo "  ✓ signature: ${SIG:0:16}…"

say "Building + validating the appcast item"
uv run --frozen python3 scripts/make_appcast.py --appcast "$APPCAST" --zip "$ZIP" \
  --tag "$TAG" --short-version "$SHORT" --build "$BUILD" --signature "$SIG" --write
git diff --stat -- "$APPCAST"

if [ "$DRY_RUN" = "--dry-run" ]; then
  say "Dry run: verifying signature locally, then rolling back the appcast"
  [ -n "${SIGN_KEY_FILE:-}" ] && PUBKEY="$(cat "${SIGN_KEY_FILE}.pub" 2>/dev/null || echo "$PUBKEY")"
  uv run --frozen python3 - "$ZIP" "$SIG" "$PUBKEY" <<'PY'
import sys; sys.path.insert(0, "scripts")
from make_appcast import verify_signature
ok = verify_signature(sys.argv[1], sys.argv[2], sys.argv[3])
print("  ✓ EdDSA signature verifies" if ok else "  ✗ signature does NOT verify"); sys.exit(0 if ok else 1)
PY
  git checkout -- "$APPCAST"
  say "Dry run complete (no release created, appcast unchanged)"
  exit 0
fi

say "Publishing the GitHub release FIRST (assets before appcast — no 404s)"
gh release create "$TAG" "$DMG" "$ZIP" --title "Pomvox $SHORT" --generate-notes

say "Waiting for the enclosure to serve HTTP 200"
URL="https://github.com/abhiram304/pomvox/releases/download/$TAG/Pomvox.zip"
for i in $(seq 1 30); do
  code="$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")"
  [ "$code" = "200" ] && break
  echo "  … $code, retry $i/30"; sleep 10
done
[ "$code" = "200" ] || die "enclosure never resolved: $URL"
echo "  ✓ $URL"

say "EdDSA-verifying the zip against SUPublicEDKey"
uv run --frozen python3 - "$ZIP" "$SIG" "$PUBKEY" <<'PY'
import sys; sys.path.insert(0, "scripts")
from make_appcast import verify_signature
ok = verify_signature(sys.argv[1], sys.argv[2], sys.argv[3])
print("  ✓ signature verifies against the shipped public key" if ok else "  ✗ MISMATCH"); sys.exit(0 if ok else 1)
PY

say "Committing the appcast LAST"
git add "$APPCAST"
git commit -m "release: appcast entry for $TAG"
git push origin main

say "Done — now bump the Homebrew cask (see header)."
echo "  raw.githubusercontent.com caches ~5 min; clients see $TAG within the day."
```

Then `chmod +x scripts/publish-release.sh`.

- [ ] **Step 2: Syntax-check and dry-run**

```bash
bash -n scripts/publish-release.sh && echo "syntax ok"
```
Expected: `syntax ok`.

Dry-run against a throwaway key and fixture zip (verifies steps 1–3 and the verify gate without touching GitHub — run on a scratch branch so the MARKETING_VERSION precondition can be satisfied):

```bash
git checkout -b scratch/publish-dry-run
BIN="$(scripts/sparkle-tools.sh)"
mkdir -p dist && echo "fixture" > dist/Pomvox.zip && echo "fixture" > dist/Pomvox.dmg
# throwaway file key (consult "$BIN/generate_keys" --help; it supports
# generating to / exporting a file — never touch the real Keychain key here);
# write the private key to /tmp/test.key and its public half to /tmp/test.key.pub
SIGN_KEY_FILE=/tmp/test.key scripts/publish-release.sh \
  "v$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' Pomvox/project.yml)" --dry-run
git checkout main && git branch -D scratch/publish-dry-run && rm -rf dist
```
Expected: "Dry run complete", appcast.xml unchanged (`git status` clean). If `sign_update`'s file-key flag is named differently in the pinned version, fix the flag in the script to match `--help` output.

- [ ] **Step 3: Point notarize-release.sh at the next step**

In `scripts/notarize-release.sh`, extend the final `say "Done"` block's echo lines with:

```bash
echo "  Next: scripts/publish-release.sh vX.Y.Z   (GitHub release + Sparkle appcast)"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/publish-release.sh scripts/notarize-release.sh
git commit -m "feat(dist): publish-release.sh — release-before-appcast ordering + EdDSA gate"
```

---

### Task 9: verify-update.sh — scripted end-to-end rehearsal

**Files:**
- Create: `scripts/verify-update.sh`

**Interfaces:**
- Consumes: `scripts/sparkle-tools.sh`, `scripts/make_appcast.py`, the Release build path from `notarize-release.sh` conventions, `POMVOX_UPDATE_FEED` (Task 3).
- Produces: a maintainer-run rehearsal script (needs GUI + Developer ID cert; NOT run by CI or by the implementing agent beyond `bash -n`).

- [ ] **Step 1: Create the rehearsal script**

Create `scripts/verify-update.sh`:

```bash
#!/usr/bin/env bash
#
# verify-update.sh — local end-to-end rehearsal of the in-app updater.
# Builds an "old" and a "new" Developer ID-signed Pomvox, serves a throwaway
# appcast on localhost, launches the old build against it, and tells you what
# to click and what to expect. Requires: GUI session, Developer ID cert,
# full Xcode. Run on the maintainer's Mac, never CI.
#
#   scripts/verify-update.sh
#
# What you should observe (the pass criteria from the design spec):
#   1. Old build launches; within ~seconds the Home banner shows
#      "Update available — v<new>".  NEVER any popup.
#   2. Click Update → inline download/progress → app relaunches by itself.
#   3. After relaunch, this script confirms the installed bundle's
#      CFBundleShortVersionString is the new version.
#   4. TCC: mic / input-monitoring rows survive (same team + bundle id).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="/tmp/pomvox-update-rehearsal"; DD="$WORK/dd"
APPDIR="$HOME/Applications"; PORT=8000
rm -rf "$WORK"; mkdir -p "$WORK/feed"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

CUR_SHORT="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' Pomvox/project.yml)"
CUR_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' Pomvox/project.yml)"
NEW_SHORT="${CUR_SHORT%.*}.$(( ${CUR_SHORT##*.} + 1 ))-rehearsal"
NEW_BUILD=$(( CUR_BUILD + 1000 ))   # clearly synthetic, always newer

say "Throwaway EdDSA key (file-based; never the real Keychain key)"
BIN="$(scripts/sparkle-tools.sh)"
KEY="$WORK/test.key"
# Consult "$BIN/generate_keys" --help: generate/export a FILE key pair here,
# private half at $KEY, public half (base64) into $PUB.
"$BIN/generate_keys" -x "$KEY" 2>/dev/null || die "adapt generate_keys flags per --help (file-key mode)"
PUB="$("$BIN/generate_keys" -p 2>/dev/null || true)"
[ -n "$PUB" ] || die "could not read the throwaway public key (see generate_keys --help)"

build_signed() { # $1=short $2=build $3=pubkey $4=outdir
  ( cd Pomvox && xcodegen generate >/dev/null )
  xcodebuild -project Pomvox/Pomvox.xcodeproj -scheme Pomvox -configuration Release \
    -derivedDataPath "$DD" -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$1" CURRENT_PROJECT_VERSION="$2" clean build | tail -2
  # Override the public key + feed inside the built app for the rehearsal:
  PL="$DD/Build/Products/Release/Pomvox.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $3" "$PL"
  codesign --force --deep --timestamp --options runtime \
    --entitlements Pomvox/Pomvox.entitlements \
    --sign "Developer ID Application" "$DD/Build/Products/Release/Pomvox.app"
  rm -rf "$4"; mkdir -p "$4"
  cp -R "$DD/Build/Products/Release/Pomvox.app" "$4/"
}

say "Building OLD ($CUR_SHORT/$CUR_BUILD) and NEW ($NEW_SHORT/$NEW_BUILD)"
build_signed "$CUR_SHORT" "$CUR_BUILD" "$PUB" "$WORK/old"
build_signed "$NEW_SHORT" "$NEW_BUILD" "$PUB" "$WORK/new"

say "Zipping + signing the NEW build, generating the local appcast"
/usr/bin/ditto -c -k --keepParent "$WORK/new/Pomvox.app" "$WORK/feed/Pomvox.zip"
SIG="$("$BIN/sign_update" --ed-key-file "$KEY" "$WORK/feed/Pomvox.zip" \
      | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LEN="$(stat -f %z "$WORK/feed/Pomvox.zip")"
cat > "$WORK/feed/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkle-project.org/xml/rss/1.0/modules/sparkle">
  <channel><title>Pomvox rehearsal</title>
    <item>
      <title>Version $NEW_SHORT</title>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEW_SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="http://localhost:$PORT/Pomvox.zip" length="$LEN"
                 type="application/octet-stream" sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
EOF

say "Installing OLD into $APPDIR and serving the feed"
rm -rf "$APPDIR/Pomvox.app"; cp -R "$WORK/old/Pomvox.app" "$APPDIR/"
( cd "$WORK/feed" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
SERVER=$!; trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

say "Launching — click Update on the Home banner when it appears"
open -W --env POMVOX_UPDATE_FEED="http://localhost:$PORT/appcast.xml" \
  "$APPDIR/Pomvox.app" || true
# (If the banner never appears, `open --env` may not have propagated — launch
#  the binary directly instead:
#  POMVOX_UPDATE_FEED="http://localhost:$PORT/appcast.xml" \
#    "$APPDIR/Pomvox.app/Contents/MacOS/Pomvox")

say "After the relaunch settles, verifying the installed version"
sleep 5
INSTALLED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APPDIR/Pomvox.app/Contents/Info.plist")"
if [ "$INSTALLED" = "$NEW_SHORT" ]; then
  printf '\n\033[1;32m✓ PASS — installed version is %s\033[0m\n' "$INSTALLED"
else
  die "installed version is $INSTALLED, expected $NEW_SHORT (did you click Update?)"
fi
echo "Cleanup: rm -rf $WORK; delete $APPDIR/Pomvox.app when done."
```

Then `chmod +x scripts/verify-update.sh`.

- [ ] **Step 2: Syntax check only** (execution is a maintainer step — GUI + cert required)

Run: `bash -n scripts/verify-update.sh && echo "syntax ok"`
Expected: `syntax ok`. In the task report, tell the user: *"scripts/verify-update.sh is ready but was not executed — it needs your GUI session and Developer ID cert. Run it before tagging the release, together with the edge-case matrix in the spec (tampered zip, wrong key, downgrade appcast, offline check, toggle-off = zero network)."*

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-update.sh
git commit -m "feat(updater): scripted local end-to-end update rehearsal"
```

---

### Task 10: Documentation truthfulness pass

**Files:**
- Modify: `README.md` (~lines 12 and 168–184), `SECURITY.md` (~lines 73–74), `SPEC.md` (~lines 58–62 and ~209), `Pomvox/project.yml` (entitlements comment ~line 77)

**Interfaces:**
- Consumes: nothing from code; ships in the same release as the updater so the docs never lie.
- Produces: docs that disclose the update check as the third sanctioned network call.

- [ ] **Step 1: Update README.md**

Read the two regions. In the intro (~line 12), extend the "only network calls" sentence to include the update check. Replace the enumeration at ~line 168 so it reads (adjusting list syntax to match the file):

> The only network calls Pomvox ever makes are:
>
> 1. The one-time model download from Hugging Face.
> 2. A once-a-day update check — an anonymous fetch of a public version file
>    (`appcast.xml`) from GitHub. On by default so security fixes actually
>    reach people; turn it off any time in Settings → General. Updates
>    install only when you click **Update**, and every download must pass
>    EdDSA signature verification and Apple's notarization checks before a
>    byte of it is trusted.
> 3. Opt-in telemetry (below) — never sends anything unless you explicitly
>    chose "Share anonymous stats".

Keep the closing sentence about the Python reference engine making no network calls (still true).

- [ ] **Step 2: Update SECURITY.md**

Extend the ~line 73 paragraph to name three network paths (model download, update check, opt-in telemetry) and add one sentence on the update trust chain:

> Updates are fetched from GitHub over HTTPS, verified against a pinned
> EdDSA public key **before extraction**, code-sign-checked by Sparkle, and
> installed only on an explicit click. An update signed by a different
> Developer ID team or bundle ID will not install — and would forfeit the
> app's TCC grants if it somehow did.

- [ ] **Step 3: Update SPEC.md**

At ~lines 58–62 ("Local-first" principle): add the update check to the sanctioned network list ("the one-time model download, a daily anonymous update check (on by default, off in one toggle, never on the dictation path), and explicit opt-in telemetry"). At ~line 209 (non-goals): confirm the "no cloud sync or account system" wording still holds and add "auto-installing updates without a user click" to the non-goals list.

- [ ] **Step 4: Update the entitlements comment in project.yml**

Change the comment at ~line 77 from "Outbound network (model download + opt-in telemetry) and mic." to "Outbound network (model download, update check, opt-in telemetry) and mic."

- [ ] **Step 5: Verify and commit**

Run: `grep -rn "only network" README.md SECURITY.md SPEC.md` — every hit mentions the update check.
Run the Python suite (`uv run --frozen pytest -q`) as a no-regression check.

```bash
git add README.md SECURITY.md SPEC.md Pomvox/project.yml
git commit -m "docs: disclose the daily update check as a sanctioned network call"
```

---

## Release runbook (human steps, AFTER the plan — not tasks)

1. Back up the EdDSA private key offline + as the `SPARKLE_ED_PRIVATE_KEY` GH secret (Task 1 checkpoint).
2. Run `scripts/verify-update.sh` + the spec's edge-case matrix on-device (Task 9 note). TCC re-grant once after the first Release-build install — known per-install behavior.
3. Bump `MARKETING_VERSION` to `0.1.11` and `CURRENT_PROJECT_VERSION` to `9` in `Pomvox/project.yml`; tag and run `scripts/notarize-release.sh`, then `scripts/publish-release.sh v0.1.11`.
4. Bump the Homebrew cask with `auto_updates true` + `:sparkle` livecheck (printed by publish-release.sh).
5. v0.1.12 is the first release delivered *through* the updater — the real end-to-end proof.
6. Update the wiki (Spec/ADR status → shipped; lessons note) after the release.
