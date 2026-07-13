# HUD Self-Healing Panel (orderFront Wedge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the window server silently refuses to order the HUD pill in, detect it (already shipped), rebuild the panel, and re-show — so a wedged HUD costs the user 0.3 s once instead of every dictation until relaunch.

**Architecture:** The 2026-07-11 live investigation proved the failure mode: on a long-running (2-day) process, `orderFrontRegardless()` on the original `NSPanel` becomes a permanent no-op — window-server property updates still work (alpha animates 0→1, CGWindowList sees the correct 420×64 frame) but `kCGWindowIsOnscreen` never goes true, while a *new* window in the same process orders in fine. So the panel window *instance* wedges, exactly like the CGEventTap (#49) and AVAudioEngine (#60 Task 3) before it. Fix in the same architectural style: (a) the existing post-show probe stops being report-only — on a miss it rebuilds the panel (fresh window-server window) and re-orders it in, verified by a second report-only probe; (b) `onWake` marks the panel stale so the next present rebuilds it proactively, alongside the tap and audio-engine rebuilds that already live there. Decisions are pure functions (`hudProbeAction`, `hudShouldRebuildStale`) so the policy is unit-tested; only thin AppKit glue is untested.

**Tech Stack:** Swift 5 / AppKit (NSPanel, CGWindowList), XcodeGen, XCTest.

## Evidence (root-cause investigation, 2026-07-11, live on the wedged process)

1. PID 32198 (up since Wed, v0.1.8): every `hud: show` for 3+ days of retained log is followed by `hud: PROBE MISS` — 5/5 that morning, including a synthetic-Fn repro.
2. External CGWindowList sampling during a synthetic 2 s press: pill window #9725 at the correct frame (510,762 420×64, layer 25), **alpha animates 0.0→1.0 correctly, `kCGWindowIsOnscreen` stays false throughout**. `orderFrontRegardless()` is the broken half; the alpha path works.
3. Same process, same instant: opening the status-item menu created window #12901 with `onscreen=true` — the process's window-server connection is healthy; only the old panel instance is wedged.
4. After relaunch (PID 85764): first show → pill `onscreen=true` at 510,762, no PROBE MISS. Fresh window heals it, deterministically.
5. Pattern: third long-lived system resource in this app to die silently across sleep/wake (CGEventTap → #49, AVAudioEngine → #60, now NSPanel). Trigger for the panel wedge is unproven (log rotation ate the first miss) but sleep/wake is the prime suspect; the self-heal in Task 2 works regardless of trigger.

## Global Constraints

- Repo lives at `~/dev/murmur` (NOT the stale `~/Desktop/projects/murmur` checkout).
- Build/test env: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select default is CommandLineTools, which xcodebuild rejects).
- After adding/removing Swift files: `cd Pomvox && xcodegen generate`.
- Test command: `cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS'`.
- Tests must not require a window server (CI runs headless-ish): policy is pure functions; never construct NSPanel in tests.
- Telemetry contract: error codes match `^[a-z0-9_]{1,40}$`, never free text.
- Never regress the <300 ms key-up→paste path: all new work is on the show/probe path, never between `stop()` and `Paster.paste`.
- Conventional commits, GPG-signed (global git config already signs). Subject <72 chars.
- One PR for the whole plan (single subsystem, three small commits) — branch `fix/hud-orderfront-selfheal`.

---

### Task 1: Pure probe policy — `hudProbeAction` (heal once, then report)

**Files:**
- Modify: `Pomvox/Sources/Engine/HudProbe.swift` (append)
- Test: `Pomvox/Tests/HudProbeTests.swift` (append)

**Interfaces:**
- Produces: `enum HudProbeAction: Equatable { case none, healAndRecheck, reportHealFailed }` and `func hudProbeAction(pillVisible: Bool, isPostHealCheck: Bool) -> HudProbeAction`. Task 2 calls this from the probe callback: the initial probe passes `isPostHealCheck: false`; the verification probe scheduled after a heal passes `true`, so a wedge can trigger at most ONE rebuild per `show()` (no 3 Hz rebuild loop if even fresh panels can't order in, e.g. locked screen).

- [ ] **Step 1: Write the failing test** (append to `Pomvox/Tests/HudProbeTests.swift`)

```swift
    // MARK: - probe policy (self-heal on miss, at most once per show)

    func testVisiblePillNeedsNoAction() {
        XCTAssertEqual(hudProbeAction(pillVisible: true, isPostHealCheck: false), .none)
    }

    func testMissTriggersHeal() {
        // The 2026-07-11 wedge: orderFrontRegardless no-ops on the old window.
        // A fresh panel is the proven fix — rebuild and verify.
        XCTAssertEqual(hudProbeAction(pillVisible: false, isPostHealCheck: false),
                       .healAndRecheck)
    }

    func testHealedPillNeedsNoAction() {
        XCTAssertEqual(hudProbeAction(pillVisible: true, isPostHealCheck: true), .none)
    }

    func testMissAfterHealOnlyReports() {
        // Never heal twice for one show(): if a FRESH panel also can't order
        // in (locked screen, exotic breakage), report and stop — no loop.
        XCTAssertEqual(hudProbeAction(pillVisible: false, isPostHealCheck: true),
                       .reportHealFailed)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS' -only-testing:PomvoxTests/HudProbeTests 2>&1 | tail -10`
Expected: BUILD FAILED — `cannot find 'hudProbeAction' in scope`.

- [ ] **Step 3: Write the implementation** (append to `Pomvox/Sources/Engine/HudProbe.swift`)

```swift
/// What the post-show probe should do with its result. The initial probe may
/// heal (rebuild the panel — a fresh window-server window orders in when a
/// wedged one won't, proven live 2026-07-11); the post-heal verification probe
/// only reports, so one show() can never rebuild more than once.
enum HudProbeAction: Equatable {
    case none              // pill on screen — nothing to do
    case healAndRecheck    // miss on the original panel — rebuild + verify
    case reportHealFailed  // miss on the REBUILT panel — log/telemetry only
}

func hudProbeAction(pillVisible: Bool, isPostHealCheck: Bool) -> HudProbeAction {
    if pillVisible { return .none }
    return isPostHealCheck ? .reportHealFailed : .healAndRecheck
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: `Test Suite 'HudProbeTests' passed` (10 tests: 6 existing + 4 new).

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git checkout -b fix/hud-orderfront-selfheal
git add Pomvox/Sources/Engine/HudProbe.swift Pomvox/Tests/HudProbeTests.swift
git commit -m "feat(hud): probe policy — heal once on miss, then report only"
```

---

### Task 2: Self-heal in `HudController` — rebuild + re-order-in on probe miss

**Files:**
- Modify: `Pomvox/Sources/Engine/HudPanel.swift:184-228` (`show`, `scheduleShowProbe`; add `orderIn`, `rebuildPanel`)

**Interfaces:**
- Consumes: `hudProbeAction(pillVisible:isPostHealCheck:)` from Task 1; existing `ensurePanel()`, `hudPillFound`, `HudProbe.onScreenWindows()`, `HudConst.pillSize`, `TelemetryProps.errorCode`.
- Produces: `private func rebuildPanel()` (orderOut + discard + `ensurePanel()`; the shared `HudRenderModel` means the new panel renders current state with no re-wiring). Task 3 reuses `rebuildPanel()` for the stale-on-wake path. New telemetry codes: `hud_selfheal_ok`, `hud_selfheal_failed` (existing `hud_not_visible` still fires on the first miss).
- No new unit tests: this is thin AppKit glue around the Task 1 policy; NSPanel can't be constructed in CI tests (Global Constraints). Verified live in Task 4.

- [ ] **Step 1: Extract `orderIn` and split the probe from the decision**

In `Pomvox/Sources/Engine/HudPanel.swift`, replace `show(_:)` and `scheduleShowProbe()` (lines 184–228) with:

```swift
    private func show(_ panel: NSPanel) {
        showGeneration &+= 1
        orderIn(panel)
        scheduleShowProbe(isPostHealCheck: false)
    }

    /// Frame + alpha + order-front, shared by show() and the self-heal re-show
    /// (which must NOT bump showGeneration — the heal belongs to the same show).
    private func orderIn(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let f = pillFrame(visibleFrame: (Double(vf.origin.x), Double(vf.origin.y),
                                         Double(vf.size.width), Double(vf.size.height)),
                          position: position)
        panel.setFrame(NSRect(x: f.x, y: f.y, width: f.w, height: f.h), display: true)
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
        NSLog("hud: show at (%.0f, %.0f) screen=%@ win=%d", f.x, f.y,
              screen?.localizedName ?? "<none>", panel.windowNumber)
    }

    /// ~0.3 s after a show, ask the window server whether the pill is really on
    /// screen. On a miss, rebuild the panel and re-order it in: a long-lived
    /// NSPanel can wedge so orderFrontRegardless() silently no-ops while a fresh
    /// window orders in fine (proven live 2026-07-11 — alpha animated, onscreen
    /// never went true, and a new window in the same process displayed). The
    /// post-heal probe only reports, so one show() rebuilds at most once.
    private func scheduleShowProbe(isPostHealCheck: Bool) {
        let gen = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.showGeneration == gen, self.prevState != "hidden"
            else { return }  // already hidden again — nothing to verify
            let visible = hudPillFound(
                windows: HudProbe.onScreenWindows(),
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                pillSize: HudConst.pillSize)
            switch hudProbeAction(pillVisible: visible, isPostHealCheck: isPostHealCheck) {
            case .none:
                if isPostHealCheck {
                    NSLog("hud: self-heal OK — rebuilt pill is on screen")
                    var p = TelemetryProps()
                    p.errorCode = "hud_selfheal_ok"
                    TelemetryClient.shared.emit(.error, props: p)
                }
            case .healAndRecheck:
                NSLog("hud: PROBE MISS — pill not on screen 0.3s after show (state=%@ appkitVisible=%@ win=%d alpha=%.2f) — rebuilding panel",
                      self.prevState,
                      self.panel?.isVisible == true ? "yes" : "no",
                      self.panel?.windowNumber ?? -1,
                      self.panel?.alphaValue ?? -1)
                var p = TelemetryProps()
                p.errorCode = "hud_not_visible"
                TelemetryClient.shared.emit(.error, props: p)
                self.rebuildPanel()
                if let fresh = self.panel { self.orderIn(fresh) }
                self.scheduleShowProbe(isPostHealCheck: true)
            case .reportHealFailed:
                NSLog("hud: self-heal FAILED — rebuilt pill still not on screen (state=%@)",
                      self.prevState)
                var p = TelemetryProps()
                p.errorCode = "hud_selfheal_failed"
                TelemetryClient.shared.emit(.error, props: p)
            }
        }
    }

    /// Discard the panel and build a fresh one — a new window-server window.
    /// The SwiftUI content re-binds automatically: `ensurePanel()` hosts
    /// `HudView(model:)` on the same shared `HudRenderModel`.
    private func rebuildPanel() {
        panel?.orderOut(nil)
        panel = nil
        panelFailed = false
        ensurePanel()
        NSLog("hud: panel rebuilt (win=%d)", panel?.windowNumber ?? -1)
    }
```

- [ ] **Step 2: Build + full test pass**

Run: `cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Manual smoke (Debug build, healthy path)**

Run a Debug build, dictate once, and check the log:
`/usr/bin/log stream --predicate 'process == "Pomvox"' | grep 'hud:'` (note: `/usr/bin/log`, the bare `log` is a shadowed builtin) — expect `hud: show at (…) win=N` and NO `PROBE MISS`, NO `self-heal` lines (healthy panels never enter the heal path).

- [ ] **Step 4: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/HudPanel.swift
git commit -m "fix(hud): self-heal — rebuild the panel when the pill fails to order in"
```

---

### Task 3: Proactive rebuild on wake — `markStale` + `onWake` wiring

**Files:**
- Modify: `Pomvox/Sources/Engine/HudLogic.swift:134-137` (append after `hudShouldShow`)
- Modify: `Pomvox/Sources/Engine/HudPanel.swift` (`markStale()`, stale check in `present`)
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift:721-723` (`onWake`)
- Test: `Pomvox/Tests/HudLogicTests.swift` (append)

**Interfaces:**
- Consumes: `rebuildPanel()` from Task 2; `NativeEngine.onWake(reason:)` (main actor, already calls `capture.markStale()` before the `isArmed` guard); `HudController` is `@MainActor` and owned by `NativeEngine` as `private let hud`.
- Produces: `func hudShouldRebuildStale(stale: Bool, prevState: String) -> Bool` (pure, HudLogic.swift), `HudController.markStale()`.

- [ ] **Step 1: Write the failing test** (append to `Pomvox/Tests/HudLogicTests.swift`)

```swift
    // MARK: - stale panel rebuild (post-sleep window-server wedge)

    func testStaleHiddenPanelRebuilds() {
        XCTAssertTrue(hudShouldRebuildStale(stale: true, prevState: "hidden"))
    }

    func testStaleVisiblePanelWaits() {
        // Never yank a panel that is currently displaying — the wedge only
        // matters at the next show, and the show-probe self-heal covers it.
        XCTAssertFalse(hudShouldRebuildStale(stale: true, prevState: "recording"))
    }

    func testFreshPanelIsLeftAlone() {
        XCTAssertFalse(hudShouldRebuildStale(stale: false, prevState: "hidden"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd -destination 'platform=macOS' -only-testing:PomvoxTests/HudLogicTests 2>&1 | tail -10`
Expected: BUILD FAILED — `cannot find 'hudShouldRebuildStale' in scope`.

- [ ] **Step 3: Implement**

Append to `Pomvox/Sources/Engine/HudLogic.swift` (after `hudShouldShow`, line 137):

```swift
/// After sleep/wake the panel's window-server window may be wedged (ordering
/// no-ops — the 2026-07-11 incident). Rebuild lazily at the next present, and
/// only while hidden: a visible panel is by definition not wedged, and the
/// show-probe self-heal covers anything that slips through.
func hudShouldRebuildStale(stale: Bool, prevState: String) -> Bool {
    stale && prevState == "hidden"
}
```

In `Pomvox/Sources/Engine/HudPanel.swift`:

1. Add next to `private var panelFailed = false`:
```swift
    private var panelStale = false
```
2. Add next to `prepare()`:
```swift
    /// Mark the panel's window-server window as suspect (sleep/wake). The next
    /// present() while hidden swaps in a fresh panel — same recovery the event
    /// tap (#49) and audio engine (#60) already get on wake.
    func markStale() { panelStale = true }
```
3. At the top of `present(_:now:)`, before `if panel == nil && !panelFailed { ensurePanel() }`:
```swift
        if hudShouldRebuildStale(stale: panelStale, prevState: prevState) {
            panelStale = false
            if panel != nil {
                NSLog("hud: rebuilding stale panel after wake")
                rebuildPanel()
            }
        }
```

In `Pomvox/Sources/Engine/NativeEngine.swift`, `onWake(reason:)` (line 721), after `capture.markStale()`:

```swift
        hud.markStale()       // a post-sleep panel can refuse to order in
```

- [ ] **Step 4: Run tests to verify pass**

Run: full `xcodebuild test` → `** TEST SUCCEEDED **` (new HudLogicTests + everything existing).

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/HudLogic.swift Pomvox/Sources/Engine/HudPanel.swift \
        Pomvox/Sources/Engine/NativeEngine.swift Pomvox/Tests/HudLogicTests.swift
git commit -m "fix(hud): rebuild the panel after wake, like the tap and audio engine"
```

---

### Task 4: Live verification + PR

No TDD — verification and ship ops.

- [ ] **Step 1: End-to-end check against a live build**

Replace `/Applications/Pomvox.app` with a Release build of this branch (or run Debug), arm, then:
1. `./scripts/verify-hud.sh` → `PASS: HUD pill visible during recording`.
2. `/usr/bin/log stream --predicate 'process == "Pomvox"' | grep -E 'hud:'` during a real dictation → `show at (…) win=N`, no `PROBE MISS`.

- [ ] **Step 2: Sleep/wake cycle**

Sleep the Mac ≥5 min (ideally overnight — the historical trigger window), wake, dictate immediately:
- Expect `hud: rebuilding stale panel after wake` then a clean `show` with no `PROBE MISS`; **or**, if the wedge strikes anyway, `PROBE MISS … rebuilding panel` followed by `self-heal OK`. Either line means the user saw a HUD.
- `hud_selfheal_failed` in the log = the fix didn't hold — file it with the log excerpt (the enriched miss line now records AppKit-side `isVisible`/`windowNumber`/`alpha` for the next investigation).

- [ ] **Step 3: Multi-day soak (async, after merge)**

Leave the app running 2–3 days of normal use (the original wedge took ~2 days to manifest). Grep retained logs weekly: `\/usr/bin/log show --last 3d --predicate 'process == "Pomvox" AND eventMessage CONTAINS "hud:"' | grep -cE 'PROBE MISS|self-heal'` — misses that self-heal are success; `self-heal FAILED` reopens the investigation.

- [ ] **Step 4: PR**

```bash
cd ~/dev/murmur
git push -u origin fix/hud-orderfront-selfheal
gh pr create --title "fix(hud): self-heal the pill when the window server wedges it" --body "..."
```
PR body: link the 2026-07-11 evidence (this plan's Evidence section), before/after log excerpts. One PR, three commits (repo convention).
Post-merge (only when asked): v0.1.10 release via `scripts/notarize-release.sh` + tap bump. Update the wiki vault (`~/vaults/pomvox-wiki`): incident note "HUD orderFront wedge" + lesson "every long-lived system resource needs a wake-rebuild + a runtime self-check".

---

## Self-review notes

- Spec coverage: detect→repair loop (Task 2), proactive wake rebuild matching tap/audio precedent (Task 3), bounded heal policy with no rebuild loops (Task 1), field observability of heal outcomes via `hud_selfheal_ok|failed` + enriched miss diagnostics (Task 2), live + soak verification (Task 4). The unknown trigger is explicitly covered: self-heal works regardless of what wedges the window.
- Type consistency: `hudProbeAction(pillVisible:isPostHealCheck:)` (Tasks 1→2), `rebuildPanel()` (Tasks 2→3), `hudShouldRebuildStale(stale:prevState:)` and `markStale()` (Task 3), telemetry codes match `^[a-z0-9_]{1,40}$`.
- Placeholders: none — every code step shows the complete code; the PR body "..." is ship-ops filled at PR time from the Evidence section.
- The old show-gate race comment/fix (zero-duration alpha animation) is preserved verbatim inside `orderIn` — this plan does not regress the #60-era fix.
