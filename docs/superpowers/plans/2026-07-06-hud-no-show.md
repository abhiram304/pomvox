# HUD No-Show Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "the HUD never appears" impossible to hit silently — fix the two confirmed upstream causes (fresh-install dead zone, post-sleep silent capture/STT failure) and instrument the HUD path so any remaining no-show is diagnosable from logs.

**Architecture:** The HUD is downstream of a chain: event tap → HotkeyMachine → AudioCapture → HudBus → HudController → NSPanel. Every observed "no HUD" report is a silent failure somewhere in that chain. This plan (a) adds observability at each boundary (HUD show/hide logging + CGWindowList self-probe, empty-transcript cause classification), (b) fixes the fresh-install dead zone (tap installs only after the ~460 MB model download; reorder so the hotkey works — and explains itself — during download), (c) rebuilds the AVAudioEngine after sleep/config changes so the mic can't silently deliver a dead stream, and (d) adds a live hotkey heartbeat to Setup so "Fn never reaches macOS" (third-party keyboards, missing relaunch after Input Monitoring grant) is visible to users.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (NSPanel), AVFoundation (AVAudioEngine), CoreGraphics (CGEventTap, CGWindowList), XcodeGen, XCTest.

## Evidence (root-cause investigation, 2026-07-06)

1. **Fresh-install dead zone (confirmed in code):** `NativeEngine.arm()` installs the event tap *after* `transcriber.prepare()` (`NativeEngine.swift:138–240`). On first run prepare() downloads ~460 MB — for minutes, pressing Fn does literally nothing. Menu-bar-only users get zero feedback. Perceived as "no HUD".
2. **Permissions chain (confirmed):** auto-arm silently degrades to `.failed` when grants are missing; an Input Monitoring grant does not reach an already-running process (relaunch required). ≤v0.1.5 had no discoverability (#56 shipped in 0.1.6).
3. **Post-sleep failure (confirmed in unified log, dev Mac, 2026-07-06 16:19–16:20):** after a ~7 h sleep, the tap and capture *worked* (7.2 s / 114,655 samples accumulated) but `transcript = <empty>` three times in a row, and the user saw no HUD. `AudioCapture` holds one long-lived `AVAudioEngine` with no `AVAudioEngineConfigurationChange`/wake handling — the classic stale-input-after-deep-sleep source. `finish()` swallows transcriber errors with `try?` (`NativeEngine.swift:431`), so "mic gave zeros" vs "STT threw" is indistinguishable.
4. **Zero observability (confirmed):** `HudController.show()/hide()` and the show-gate have no logging and no on-screen self-check; user reports are undiagnosable after the fact.
5. **Hotkey reachability (plausible, untested):** PTT default is Fn-only. Many third-party desktop keyboards handle Fn in hardware — it never reaches macOS. A Mac Studio has no built-in keyboard. Task 5 makes this visible; it does not add a new binding (config already supports `right_option`).
6. Hygiene: the dev Mac's `/Applications/Pomvox.app` is v0.1.1 (six releases stale); the fade-race `showGeneration` fix is already in v0.1.1+, so it is *not* the cause.

## Global Constraints

- Build/test env: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select default is CommandLineTools, which xcodebuild rejects).
- After adding/removing Swift files: `cd Pomvox && xcodegen generate`.
- Test command: `cd Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS'`.
- Never regress the <300 ms key-up→paste path: no new synchronous work between `stop()` and `Paster.paste`.
- Telemetry contract: error codes match `^[a-z0-9_]{1,40}$`, never free text.
- Conventional commits, GPG-signed (global git config already signs). Subject <72 chars.
- One PR per task (repo convention: small stacked PRs).
- The repo lives at `~/dev/murmur` (NOT the stale `~/Desktop/projects/murmur` checkout).

---

### Task 1: HUD render-path observability (logging + on-screen self-probe)

**Files:**
- Create: `Pomvox/Sources/Engine/HudProbe.swift`
- Modify: `Pomvox/Sources/Engine/HudPanel.swift:184-215` (`show`/`hide`)
- Test: `Pomvox/Tests/HudProbeTests.swift`

**Interfaces:**
- Produces: `struct HudWindowInfo { var ownerPID: Int; var size: CGSize; var alpha: Double; var layer: Int }`, `func hudPillFound(windows: [HudWindowInfo], pid: Int, pillSize: CGSize, tolerance: CGFloat = 2.0) -> Bool`, `enum HudProbe { static func onScreenWindows() -> [HudWindowInfo] }`. Task 6's verify script reuses the same CGWindowList approach externally.

- [ ] **Step 1: Write the failing test**

```swift
// Pomvox/Tests/HudProbeTests.swift
import XCTest
@testable import Pomvox

/// The post-show self-probe: given CGWindowList-shaped rows, is a pill-sized
/// window of ours actually on screen? Pure decision so it runs without a
/// window server (CI).
final class HudProbeTests: XCTestCase {
    private let pill = HudConst.pillSize  // 420×64

    private func win(pid: Int = 42, w: CGFloat = 420, h: CGFloat = 64,
                     alpha: Double = 1.0, layer: Int = 25) -> HudWindowInfo {
        HudWindowInfo(ownerPID: pid, size: CGSize(width: w, height: h),
                      alpha: alpha, layer: layer)
    }

    func testFindsThePill() {
        XCTAssertTrue(hudPillFound(windows: [win()], pid: 42, pillSize: pill))
    }

    func testIgnoresOtherProcessesWindows() {
        XCTAssertFalse(hudPillFound(windows: [win(pid: 7)], pid: 42, pillSize: pill))
    }

    func testIgnoresWrongSizedWindows() {
        // The Hub window, menus, etc. — only the 420×64 pill counts.
        XCTAssertFalse(hudPillFound(windows: [win(w: 900, h: 600)], pid: 42, pillSize: pill))
    }

    func testToleratesSubpixelRounding() {
        XCTAssertTrue(hudPillFound(windows: [win(w: 421, h: 63.5)], pid: 42, pillSize: pill))
    }

    func testFullyTransparentPillDoesNotCount() {
        // alpha 0 = the fade-out completed / show never applied alpha 1.
        XCTAssertFalse(hudPillFound(windows: [win(alpha: 0.0)], pid: 42, pillSize: pill))
    }

    func testEmptyWindowListDoesNotCount() {
        XCTAssertFalse(hudPillFound(windows: [], pid: 42, pillSize: pill))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/dev/murmur/Pomvox && xcodegen generate && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS' -only-testing:PomvoxTests/HudProbeTests 2>&1 | tail -20`
Expected: BUILD FAILED — `cannot find type 'HudWindowInfo' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Pomvox/Sources/Engine/HudProbe.swift
import CoreGraphics
import Foundation

/// Post-show self-check for the HUD pill. "The HUD never appeared" reports are
/// undiagnosable without ground truth about what the window server actually
/// displayed — this asks CGWindowList whether a pill-sized window of ours is on
/// screen ~0.3 s after `show()`. The decision is pure (`hudPillFound`) so it is
/// unit-tested; only the collector touches the window server.
struct HudWindowInfo: Equatable {
    var ownerPID: Int
    var size: CGSize
    var alpha: Double
    var layer: Int
}

/// Does *windows* contain an on-screen, non-transparent window owned by *pid*
/// whose size matches the HUD pill (within *tolerance* pts for rounding)?
func hudPillFound(windows: [HudWindowInfo], pid: Int,
                  pillSize: CGSize, tolerance: CGFloat = 2.0) -> Bool {
    windows.contains { w in
        w.ownerPID == pid && w.alpha > 0.01
            && abs(w.size.width - pillSize.width) <= tolerance
            && abs(w.size.height - pillSize.height) <= tolerance
    }
}

enum HudProbe {
    /// Snapshot of all on-screen windows (any process). `optionOnScreenOnly`
    /// already excludes ordered-out and fully-hidden windows.
    static func onScreenWindows() -> [HudWindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return raw.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return HudWindowInfo(
                ownerPID: pid,
                size: CGSize(width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0),
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1.0,
                layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: `Test Suite 'HudProbeTests' passed` (6 tests).

- [ ] **Step 5: Wire logging + the probe into `HudController`**

In `Pomvox/Sources/Engine/HudPanel.swift`, replace `show(_:)` and `hide(_:)` (lines 184–215) with:

```swift
    private func show(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let f = pillFrame(visibleFrame: (Double(vf.origin.x), Double(vf.origin.y),
                                         Double(vf.size.width), Double(vf.size.height)),
                          position: position)
        panel.setFrame(NSRect(x: f.x, y: f.y, width: f.w, height: f.h), display: true)
        showGeneration &+= 1
        // Cancel any in-flight fade-out: a re-record that lands inside hide()'s
        // 0.25 s fade would otherwise keep animating alpha back to 0 and the HUD
        // never appears. Re-assigning alpha through a zero-duration animation
        // replaces the running animation instead of racing it; a bare
        // `alphaValue = 1.0` does not, which was the intermittent no-show.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1.0
        }
        panel.orderFrontRegardless()           // never makeKeyAndOrderFront
        NSLog("hud: show at (%.0f, %.0f) screen=%@", f.x, f.y,
              screen?.localizedName ?? "<none>")
        scheduleShowProbe()
    }

    /// ~0.3 s after a show, ask the window server whether the pill is really on
    /// screen. A miss is the "HUD never appeared" bug caught red-handed — one
    /// log line + one anonymous error event, never any UI.
    private func scheduleShowProbe() {
        let gen = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.showGeneration == gen, self.prevState != "hidden"
            else { return }  // already hidden again — nothing to verify
            let visible = hudPillFound(
                windows: HudProbe.onScreenWindows(),
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                pillSize: HudConst.pillSize)
            if !visible {
                NSLog("hud: PROBE MISS — pill not on screen 0.3s after show (state=%@)",
                      self.prevState)
                var p = TelemetryProps()
                p.errorCode = "hud_not_visible"
                TelemetryClient.shared.emit(.error, props: p)
            }
        }
    }

    private func hide(_ panel: NSPanel) {
        let gen = showGeneration
        NSLog("hud: hide (fade) state=%@", prevState)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            // Only retire the panel if no show() reclaimed it during the fade.
            guard let self, self.showGeneration == gen else { return }
            if panel.alphaValue == 0.0 { panel.orderOut(nil) }
        })
    }
```

(If `TelemetryProps`'s error-code property has a different name in `Telemetry.swift`, match it — `NativeEngine.errorProps(_:)` shows the exact shape.)

- [ ] **Step 6: Build + full test pass**

Run: `xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/HudProbe.swift Pomvox/Sources/Engine/HudPanel.swift \
        Pomvox/Tests/HudProbeTests.swift Pomvox/Pomvox.xcodeproj
git commit -m "feat(hud): log show/hide + CGWindowList self-probe after show"
```

---

### Task 2: Classify empty transcripts (silent mic vs STT failure) and say so

**Files:**
- Create: `Pomvox/Sources/Engine/EmptyTranscript.swift`
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift:407-450` (`finish()`)
- Test: `Pomvox/Tests/EmptyTranscriptTests.swift`

**Interfaces:**
- Produces: `func peakDbfs(_ samples: [Float]) -> Double`, `enum EmptyTranscriptCause: Equatable { case sttFailed(String); case silentAudio(Double); case noSpeech(Double) }` with `var errorCode: String?` and `var hudMessage: String?`, `func classifyEmptyTranscript(peakDbfs: Double, sttError: String?, silenceFloorDbfs: Double = -70.0) -> EmptyTranscriptCause`.
- Consumes: `HudStateMachine` result semantics (`.result("error", msg)` flashes ~2.5 s; `.result("empty", "")` hides silently).

- [ ] **Step 1: Write the failing test**

```swift
// Pomvox/Tests/EmptyTranscriptTests.swift
import XCTest
@testable import Pomvox

/// When STT returns "", the user must learn WHY nothing pasted: the transcriber
/// threw (bug), the mic delivered (near-)zeros (the post-sleep dead-stream
/// failure), or there genuinely were no words (normal — stay silent).
final class EmptyTranscriptTests: XCTestCase {

    func testSttErrorWinsOverEverything() {
        let c = classifyEmptyTranscript(peakDbfs: -90.0, sttError: "ANE context invalid")
        XCTAssertEqual(c, .sttFailed("ANE context invalid"))
        XCTAssertEqual(c.errorCode, "stt_failed")
        XCTAssertNotNil(c.hudMessage)
    }

    func testNearZeroAudioIsSilentAudio() {
        let c = classifyEmptyTranscript(peakDbfs: -80.0, sttError: nil)
        XCTAssertEqual(c, .silentAudio(-80.0))
        XCTAssertEqual(c.errorCode, "silent_audio")
        XCTAssertTrue(c.hudMessage!.lowercased().contains("mic"))
    }

    func testAudibleAudioWithNoWordsStaysQuiet() {
        // Breathing / keyboard noise transcribing to "" is normal — no flash.
        let c = classifyEmptyTranscript(peakDbfs: -35.0, sttError: nil)
        XCTAssertEqual(c, .noSpeech(-35.0))
        XCTAssertNil(c.errorCode)
        XCTAssertNil(c.hudMessage)
    }

    func testPeakDbfsOfSilenceIsFloor() {
        XCTAssertLessThan(peakDbfs([Float](repeating: 0.0, count: 16000)), -100.0)
    }

    func testPeakDbfsOfFullScale() {
        XCTAssertEqual(peakDbfs([0.0, 1.0, -0.5]), 0.0, accuracy: 0.01)
    }

    func testPeakDbfsOfEmptyBufferIsFloor() {
        XCTAssertLessThan(peakDbfs([]), -100.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test ... -only-testing:PomvoxTests/EmptyTranscriptTests 2>&1 | tail -10` (full flags as in Global Constraints)
Expected: BUILD FAILED — `cannot find 'classifyEmptyTranscript' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Pomvox/Sources/Engine/EmptyTranscript.swift
import Foundation

/// Peak level of an utterance in dBFS. Distinguishes "the mic delivered
/// (near-)zeros" (dead stream after deep sleep) from "audible audio with no
/// recognizable words" — `blockDbfs` is RMS over a block; for the whole
/// utterance the peak is the honest liveness signal.
func peakDbfs(_ samples: [Float]) -> Double {
    var peak: Float = 0
    for s in samples { peak = max(peak, abs(s)) }
    return 20 * log10(Double(peak) + 1e-12)
}

/// Why did a non-trivial recording transcribe to ""? Ordered by blame:
/// a thrown STT error is a bug; a silent capture is a hardware/driver fault
/// the user must hear about; true no-speech is normal and stays quiet.
enum EmptyTranscriptCause: Equatable {
    case sttFailed(String)     // transcriber threw — the error text (logs only)
    case silentAudio(Double)   // peak dBFS below floor — mic gave (near-)zeros
    case noSpeech(Double)      // audio had energy, just no words — not an error

    /// Anonymous telemetry code (contract: ^[a-z0-9_]{1,40}$); nil = not an error.
    var errorCode: String? {
        switch self {
        case .sttFailed: "stt_failed"
        case .silentAudio: "silent_audio"
        case .noSpeech: nil
        }
    }

    /// HUD error-flash copy; nil = hide silently (today's behavior).
    var hudMessage: String? {
        switch self {
        case .sttFailed: "transcription failed — try again"
        case .silentAudio: "mic captured silence — check your input device"
        case .noSpeech: nil
        }
    }
}

func classifyEmptyTranscript(peakDbfs: Double, sttError: String?,
                             silenceFloorDbfs: Double = -70.0) -> EmptyTranscriptCause {
    if let sttError { return .sttFailed(sttError) }
    if peakDbfs < silenceFloorDbfs { return .silentAudio(peakDbfs) }
    return .noSpeech(peakDbfs)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2. Expected: 6 tests pass.

- [ ] **Step 5: Wire into `finish()`**

In `Pomvox/Sources/Engine/NativeEngine.swift` inside the `Task` in `finish()`:

Replace (line ~431):
```swift
            let raw = (try? await self.transcriber.transcribe(samples)) ?? ""
            timings.stamp("stt_finalize")
            NSLog("pomvox-engine: transcript = %@", raw.isEmpty ? "<empty>" : raw)
```
with:
```swift
            var sttError: String?
            var raw = ""
            do {
                raw = try await self.transcriber.transcribe(samples)
            } catch {
                sttError = String(describing: error)
                NSLog("pomvox-engine: finalize transcribe FAILED: %@", sttError!)
            }
            timings.stamp("stt_finalize")
            NSLog("pomvox-engine: transcript = %@ (peak %.0f dBFS)",
                  raw.isEmpty ? "<empty>" : raw, peakDbfs(samples))
```

Then in the `MainActor.run` block, replace the empty-text branch:
```swift
                guard !text.isEmpty else {
                    self.bus.post(.result("empty", ""))
                    self.doneMachine()
                    self.status = .ready
                    return (nil, nil)
                }
```
with:
```swift
                guard !text.isEmpty else {
                    let cause = classifyEmptyTranscript(
                        peakDbfs: peakDbfs(samples), sttError: sttError)
                    if let msg = cause.hudMessage {
                        self.bus.post(.result("error", msg))
                    } else {
                        self.bus.post(.result("empty", ""))
                    }
                    if let code = cause.errorCode {
                        NSLog("pomvox-engine: empty transcript — %@", code)
                        TelemetryClient.shared.emit(.error, props: self.errorProps(code))
                    }
                    self.doneMachine()
                    self.status = .ready
                    return (nil, nil)
                }
```
(`samples` is already captured by the Task closure; `peakDbfs` over ≤600 s of 16 kHz floats is a ~10 M-element scan, <5 ms, and runs only on the empty-transcript path — the paste path is untouched.)

- [ ] **Step 6: Full test pass, then commit**

Run: full `xcodebuild test` → `** TEST SUCCEEDED **`.

```bash
git add Pomvox/Sources/Engine/EmptyTranscript.swift Pomvox/Sources/Engine/NativeEngine.swift \
        Pomvox/Tests/EmptyTranscriptTests.swift Pomvox/Pomvox.xcodeproj
git commit -m "feat(engine): classify empty transcripts — silent mic vs STT failure"
```

---

### Task 3: Rebuild the audio engine after sleep / device configuration changes

**Files:**
- Modify: `Pomvox/Sources/Engine/AudioCapture.swift` (engine becomes rebuildable)
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift:595-604` (`onWake`)
- Test: `Pomvox/Tests/AudioCaptureFailureTests.swift` (append)

**Interfaces:**
- Produces: `AudioCapture.markStale()` (thread-safe; next `start()` builds a fresh `AVAudioEngine`), `private(set) var rebuildCount: Int` (observability + tests).
- Consumes: `NativeEngine.onWake(reason:)` already runs on the main actor and already recreates the event tap.

- [ ] **Step 1: Write the failing test** (append to `AudioCaptureFailureTests.swift`)

```swift
    // MARK: - stale-engine rebuild (post-sleep dead stream)

    func testMarkStaleForcesRebuildOnNextStart() {
        let capture = AudioCapture()
        capture.markStale()
        // start() may throw on CI (no mic grant) — the rebuild happens first
        // and must be counted either way.
        _ = try? capture.start()
        XCTAssertEqual(capture.rebuildCount, 1)
        capture.stop()
    }

    func testStartWithoutStaleDoesNotRebuild() {
        let capture = AudioCapture()
        _ = try? capture.start()
        XCTAssertEqual(capture.rebuildCount, 0)
        capture.stop()
    }

    func testMarkStaleIsIdempotentPerStart() {
        let capture = AudioCapture()
        capture.markStale()
        capture.markStale()
        _ = try? capture.start()
        XCTAssertEqual(capture.rebuildCount, 1)
        capture.stop()
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:PomvoxTests/AudioCaptureFailureTests 2>&1 | tail -10`
Expected: BUILD FAILED — `value of type 'AudioCapture' has no member 'markStale'`.

- [ ] **Step 3: Implement**

In `Pomvox/Sources/Engine/AudioCapture.swift`:

Change `private let engine = AVAudioEngine()` to:
```swift
    // `var`: rebuilt when marked stale — a long-lived AVAudioEngine can keep
    // "running" after deep sleep or a default-device change while delivering a
    // dead (all-zero) stream. A fresh engine re-binds to live hardware.
    private var engine = AVAudioEngine()
    private var stale = false
    private(set) var rebuildCount = 0
    private var configObserver: NSObjectProtocol?
```

In `init()`, after `targetFormat = ...`:
```swift
        // The engine posts this when the input device / format changes under it
        // (sleep-wake, AirPods connect, default-device switch). Rebinding lazily
        // at the next start() is enough — mid-recording changes end the session
        // via the engine stopping on its own.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            NSLog("audio: engine configuration changed — marked stale")
            self.markStale()
        }
```

Add after `init()`:
```swift
    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Next `start()` builds a fresh AVAudioEngine. Thread-safe; called from the
    /// wake handler and the configuration-change notification.
    func markStale() { lock.lock(); stale = true; lock.unlock() }
```

At the top of `start()`, replace:
```swift
        lock.lock(); samples.removeAll(keepingCapacity: true); recording = true; lock.unlock()
```
with:
```swift
        lock.lock()
        samples.removeAll(keepingCapacity: true); recording = true
        let needsFresh = stale; stale = false
        lock.unlock()
        if needsFresh {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            rebuildCount += 1
            NSLog("audio: engine rebuilt (stale after sleep/config change)")
        }
```

In `Pomvox/Sources/Engine/NativeEngine.swift`, in `onWake(reason:)` after `panicReset(...)`:
```swift
        capture.markStale()   // a post-sleep engine can deliver a dead stream
```

- [ ] **Step 4: Run tests to verify pass**

Run: full `xcodebuild test` → `** TEST SUCCEEDED **` (new + existing AudioCapture tests).

- [ ] **Step 5: Commit**

```bash
git add Pomvox/Sources/Engine/AudioCapture.swift Pomvox/Sources/Engine/NativeEngine.swift \
        Pomvox/Tests/AudioCaptureFailureTests.swift
git commit -m "fix(engine): rebuild audio engine after sleep/config change"
```

---

### Task 4: Kill the fresh-install dead zone — hotkey live during model download

**Files:**
- Modify: `Pomvox/Sources/Engine/HudLogic.swift:227` (result gate)
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift:138-240` (`arm()` ordering), `:383` (`startCapture`)
- Test: `Pomvox/Tests/HudLogicTests.swift` (append)

**Interfaces:**
- Consumes: `speechLoad: String?` (existing published download-progress line, e.g. "Speech model — downloading 42%"), `HudConst.errorFlashS`.
- Produces: `.result("error", msg)` now flashes even from the hidden state; `arm()` installs the tap before `transcriber.prepare()`.

- [ ] **Step 1: Write the failing test** (append to `HudLogicTests.swift`)

```swift
    func testErrorResultFlashesEvenWhileHidden() {
        // A press during model download / a failed capture start must be able
        // to say why nothing is happening — errors flash from any state.
        let m = make()
        let vm = m.apply([.result: .result("error", "still downloading the speech model")], now: 1.0)
        XCTAssertEqual(vm.state, "error")
        XCTAssertTrue(vm.status.contains("downloading"))
        XCTAssertNotNil(vm.hideAt)
    }

    func testOkResultWhileHiddenIsStillIgnored() {
        // Only errors escape the gate — a stale "ok" from a cancelled session
        // must not flash "done" out of nowhere.
        let m = make()
        let vm = m.apply([.result: .result("ok", "ghost")], now: 1.0)
        XCTAssertFalse(vm.visible)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:PomvoxTests/HudLogicTests 2>&1 | tail -10`
Expected: `testErrorResultFlashesEvenWhileHidden` FAILS (state stays "hidden").

- [ ] **Step 3: Relax the gate for errors only**

In `Pomvox/Sources/Engine/HudLogic.swift`, in `HudStateMachine.one`, replace:
```swift
        case let .result(status, text):
            guard vm.visible else { return }
```
with:
```swift
        case let .result(status, text):
            // Errors flash from ANY state — a press that can't start (model
            // still downloading, mic dead) must say so; everything else keeps
            // the old gate (a stale ok/cancelled must not flash from hidden).
            guard vm.visible || status == "error" else { return }
```

- [ ] **Step 4: Run tests to verify pass**

Run: same as Step 2. Expected: all HudLogicTests pass (existing vectors all enter from `recording`, unaffected).

- [ ] **Step 5: Reorder `arm()` — tap before model download**

In `Pomvox/Sources/Engine/NativeEngine.swift` `arm()`:

1. Move this block (currently after the cleanup-LLM block) to immediately after `loadEngineConfig()`:
```swift
        // The audio callback posts mic level (waveform) and, when armed, drives
        // the VAD endpointer. Set before any capture.start().
        capture.onBlock = { [weak self] block in self?.onAudioBlock(block) }

        // Tap FIRST, model second: on a fresh install prepare() downloads
        // ~460 MB — with the tap already live, a press during the download
        // flashes "still downloading" instead of doing nothing (the
        // fresh-install "app is dead" report). startCapture() gates on .ready.
        let tap = makeTap()
        do {
            try tap.start()
            NSLog("pomvox-engine: event tap installed")
        } catch {
            NSLog("pomvox-engine: event tap FAILED (Input Monitoring?): %@", String(describing: error))
            pidfile.release()
            history?.close(); history = nil
            status = .failed(
                "Input Monitoring isn't granted. Enable Pomvox in System Settings ▸ Privacy & "
                + "Security ▸ Input Monitoring, then turn this on again.")
            TelemetryClient.shared.emit(.error, props: errorProps("input_monitoring_denied"))
            return
        }
        self.tap = tap
```
2. Delete the original tap-install block from its old position.
3. In the model-load `catch` branch (`model load FAILED`), add tap teardown so a failed arm leaves no live tap:
```swift
            tap.stop(); self.tap = nil
```
(add alongside the existing `pidfile.release()` / `history?.close()` lines there).

- [ ] **Step 6: Gate `startCapture` on readiness with a spoken reason**

At the top of `startCapture(mode:)` (`NativeEngine.swift:383`):
```swift
        // Tap is live before the model is (fresh-install download): a press
        // that can't record yet must say why instead of doing nothing.
        guard status == .ready || status == .recording else {
            let line = speechLoad ?? polishLoad
            let msg = line.map { "not ready yet — \($0)" }
                ?? "Pomvox is still starting up — try again in a moment"
            NSLog("pomvox-engine: press before ready (status not .ready) — %@", msg)
            bus.post(.result("error", msg))
            resetMachine()
            return
        }
```

- [ ] **Step 7: Full test pass + manual smoke**

Run: full `xcodebuild test` → `** TEST SUCCEEDED **`.
Manual: `rm -rf ~/Library/Caches/huggingface` (or a fresh user account) → launch a Debug build → press Fn during the download → the HUD must flash "not ready yet — Speech model — downloading N%".

- [ ] **Step 8: Commit**

```bash
git add Pomvox/Sources/Engine/HudLogic.swift Pomvox/Sources/Engine/NativeEngine.swift \
        Pomvox/Tests/HudLogicTests.swift
git commit -m "feat(engine): hotkey live during first-run download, errors flash from hidden"
```

---

### Task 5: Hotkey heartbeat in Setup — see whether Fn ever reaches the app

**Files:**
- Modify: `Pomvox/Sources/Engine/HotkeyMachine.swift` (expose `pttKeycode`)
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift:309` (`decide` stamps the heartbeat)
- Modify: `Pomvox/Sources/SetupView.swift` (live "press your key" row)
- Test: `Pomvox/Tests/HotkeyMachineTests.swift` (append)

**Interfaces:**
- Produces: `HotkeyMachine.pttKeycode: Int`, `NativeEngine.lastPttSeenAt: Date?` (`@Published private(set)`).
- Why: distinguishes the three "nothing happens" worlds — tap not installed (grant/relaunch), tap installed but Fn never arrives (third-party keyboard hardware Fn — the likely Mac Studio case), or events arriving fine (problem is downstream).

- [ ] **Step 1: Failing test** (append to `HotkeyMachineTests.swift`)

```swift
    func testExposesThePttKeycodeForTheHeartbeat() throws {
        XCTAssertEqual(try HotkeyMachine().pttKeycode, 63)                       // fn
        XCTAssertEqual(try HotkeyMachine(ptt: "right_option").pttKeycode, 61)
    }
```
(Match the file's existing construction style — if `HotkeyMachine()` isn't `throws` there, drop the `try`.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:PomvoxTests/HotkeyMachineTests 2>&1 | tail -8`
Expected: BUILD FAILED — no member `pttKeycode`.

- [ ] **Step 3: Implement**

`HotkeyMachine.swift` — add next to the stored `pttKey`:
```swift
    /// The PTT virtual keycode, exposed for the Setup heartbeat ("is your key
    /// reaching Pomvox at all?" — hardware Fn keys on third-party keyboards
    /// often never generate an event).
    var pttKeycode: Int { pttKey }
```

`NativeEngine.swift` — add near the other `@Published` vars:
```swift
    // Setup heartbeat: last time the PTT key's own event reached the tap.
    // Distinguishes "tap dead / key handled in keyboard hardware" (stays nil)
    // from "events arrive, problem is downstream".
    @Published private(set) var lastPttSeenAt: Date?
```
In `decide(_:)` (line ~309), the closures passed to `makeTap` call `decide` for every modifier/key event; stamp only PTT-keycode events. Inside `decide`, after computing `decision` (still under no lock needed for the stamp):
```swift
        if isPttKeycode { Task { @MainActor [weak self] in self?.lastPttSeenAt = Date() } }
```
Thread the keycode through: change `decide` to accept it —
```swift
    private nonisolated func decide(
        keycode: Int? = nil,
        _ body: (HotkeyMachine) -> HotkeyMachine.Decision
    ) -> HotkeyMachine.Decision {
        machineLock.lock()
        let decision = body(machine)
        let isPtt = keycode == machine.pttKeycode
        if decision.action == .stop { stopAt = CFAbsoluteTimeGetCurrent() }
        machineLock.unlock()
        if isPtt { Task { @MainActor [weak self] in self?.lastPttSeenAt = Date() } }
        if decision.action != .none {
            let action = decision.action
            Task { @MainActor [weak self] in self?.handle(action) }
        }
        return decision
    }
```
and in `makeTap`'s `onModifier` closure pass it: `self?.decide(keycode: keycode) { $0.onModifier(keycode, isDown) } ?? ...` (leave `onKeyDown` without a keycode — space isn't the PTT key). `machine` is `nonisolated(unsafe)` and `pttKeycode` reads an immutable `let`, so reading it under `machineLock` is safe.

- [ ] **Step 4: Setup row**

In `Pomvox/Sources/SetupView.swift`, below the permission rows (`PermissionRow` list, around line 72), add a liveness row following the pane's existing row styling:
```swift
            // Hotkey heartbeat: proves the dictation key physically reaches the
            // app. Green within 10 s of a press; the hint covers the two known
            // silent worlds (hardware Fn keys, missing relaunch after a grant).
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let seen = engine.lastPttSeenAt.map {
                    context.date.timeIntervalSince($0) < 10.0 } ?? false
                HStack(spacing: 8) {
                    Image(systemName: seen ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(seen ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seen ? "Hotkey working — Fn reaches Pomvox"
                                  : "Press Fn to test your dictation key")
                        if !seen {
                            Text("No key event? Third-party keyboards may handle Fn in hardware — set [hotkey] ptt = \"right_option\" in config.toml. Just granted Input Monitoring? Relaunch Pomvox.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
```
(Adapt container/styling to the surrounding pane — reuse `PermissionRow`'s visual language if it composes cleanly.)

- [ ] **Step 5: Full test pass, manual check, commit**

Run: full `xcodebuild test` → `** TEST SUCCEEDED **`.
Manual: Debug build → Setup pane → press Fn → row turns green within a second.

```bash
git add Pomvox/Sources/Engine/HotkeyMachine.swift Pomvox/Sources/Engine/NativeEngine.swift \
        Pomvox/Sources/SetupView.swift Pomvox/Tests/HotkeyMachineTests.swift
git commit -m "feat(setup): live hotkey heartbeat — see whether Fn reaches the app"
```

---

### Task 6: Verify end-to-end, refresh the dev install, ship v0.1.7

No TDD here — this is verification + release ops.

- [ ] **Step 1: End-to-end HUD verify script**

Create `scripts/verify-hud.sh`:
```bash
#!/bin/bash
# End-to-end HUD check: synthesize an Fn press (needs Accessibility for the
# terminal), hold 2 s, release, and ask the window server whether the 420×64
# pill appeared. Run against a live, armed Pomvox.
set -euo pipefail
swift - <<'EOF'
import CoreGraphics
import Foundation

func fn(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
    e.type = .flagsChanged
    e.flags = down ? .maskSecondaryFn : []
    e.post(tap: .cgSessionEventTap)
}

func pillOnScreen() -> Bool {
    let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return wins.contains { w in
        guard (w["kCGWindowOwnerName"] as? String) == "Pomvox",
              let b = w["kCGWindowBounds"] as? [String: CGFloat] else { return false }
        return abs((b["Width"] ?? 0) - 420) <= 2 && abs((b["Height"] ?? 0) - 64) <= 2
    }
}

fn(true)
Thread.sleep(forTimeInterval: 2.0)
let visible = pillOnScreen()
fn(false)
Thread.sleep(forTimeInterval: 1.0)
print(visible ? "PASS: HUD pill visible during recording" : "FAIL: HUD pill NOT visible")
exit(visible ? 0 : 1)
EOF
```
`chmod +x scripts/verify-hud.sh`. Caution: releases Fn after 2 s — run with a text editor focused so any stray paste is harmless.

- [ ] **Step 2: Replace the stale dev install**

The dev Mac is running v0.1.1. Build Release from HEAD (Developer ID config per `scripts/notarize-release.sh` or a local Release build), quit Pomvox, replace `/Applications/Pomvox.app`, relaunch, re-grant if TCC prompts.

- [ ] **Step 3: Live verification matrix**

1. `./scripts/verify-hud.sh` → PASS, and `log stream --predicate 'process == "Pomvox"' | grep "hud:"` shows `show at (…)` with no `PROBE MISS`.
2. Real dictation → paste lands, HUD full lifecycle.
3. Unplug/replug or switch the default mic mid-idle → next dictation logs `audio: engine rebuilt` and transcribes.
4. **Overnight sleep repro** (the original failure): sleep the Mac ≥1 h, wake, dictate immediately. Expect either a working dictation (Task 3 fixed it) or — now diagnosable — `hud: PROBE MISS` / `silent_audio` / `stt_failed` in the log. If `PROBE MISS` appears, that's the remaining HUD bug caught with evidence: file it with the log excerpt.
5. Fresh-install sim: new macOS user account, mount the DMG, full first-run — press Fn *during* the model download and expect the "not ready yet" flash.
6. Mac Studio: repeat install; if the Setup heartbeat row never turns green on Fn, the keyboard eats Fn — set `ptt = "right_option"` and re-test (this confirms or kills hypothesis 5).

- [ ] **Step 4: Commit script, PR, release**

```bash
git add scripts/verify-hud.sh
git commit -m "test(hud): end-to-end synthetic-Fn HUD visibility check"
```
Open one PR per task (stack in order 1→5; 6's script can ride with 1 or alone). After merge: cut v0.1.7 via the existing release flow (`scripts/notarize-release.sh`, DMG, tag, GitHub release, bump the homebrew tap).

---

## Self-review notes

- Spec coverage: fresh-install dead zone → Task 4; permissions/relaunch visibility → Task 5 (heartbeat + hint); post-sleep silent capture → Tasks 2+3; HUD-path observability → Task 1; stale dev install + end-to-end proof + user-report loop → Task 6. The post-sleep HUD no-show itself has no *speculative* fix — Task 1's probe is the instrument that converts the next occurrence into a diagnosis; Task 3 removes the most likely upstream cause.
- Type consistency: `HudWindowInfo`/`hudPillFound` (Tasks 1, 6 script uses raw CGWindowList — independent), `peakDbfs`/`classifyEmptyTranscript` (Task 2), `markStale`/`rebuildCount` (Task 3), `pttKeycode`/`lastPttSeenAt` (Task 5) — names match across tasks.
- Placeholders: none; two "adapt to surrounding style" notes are for cosmetic SwiftUI container reuse and property-name verification against `Telemetry.swift`, with concrete fallback code provided.
