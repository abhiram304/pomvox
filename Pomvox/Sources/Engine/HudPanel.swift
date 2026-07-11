import AppKit
import QuartzCore
import SwiftUI

/// The never-steals-focus floating panel. Five-point recipe from `hud.py`'s
/// `HudPanel`: a non-key/non-main NSPanel, borderless | nonactivatingPanel mask,
/// `hidesOnDeactivate` off, status window level, joins all Spaces incl.
/// fullscreen, ignores mouse, shown with `orderFrontRegardless` only;
/// `sharingType = .none` keeps the live draft out of screen shares. The paste
/// lands in the user's frontmost app because this window can never take focus.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Glue owned by `NativeEngine` (main actor): state machine + panel + the 15 Hz
/// waveform sampling timer + hide-deadline ticks + entry sounds. `render` is the
/// `HudBus` main-thread callback. Honors `[hud]` position / show_draft / sounds.
@MainActor
final class HudController {
    private let machine: HudStateMachine
    private let model = HudRenderModel()
    private var panel: NonActivatingPanel?
    private var panelFailed = false
    private var occlusionObserver: NSObjectProtocol?
    private var panelStale = false

    private var enabled = true
    private var position: String
    private var sounds: Bool

    private let history = LevelHistory()
    private var currentLevel = 0.0
    private var waveTimer: Timer?
    private var hideTimer: Timer?

    private var displayedDraft = ""
    private var prevState = "hidden"
    // Bumped on every show(); a hide() fade started before the latest show must
    // not retire the panel that show reclaimed (guards the re-record-during-fade
    // race — the intermittent HUD-no-show).
    private var showGeneration = 0

    init(position: String = "bottom-center", showDraft: Bool = true,
         sounds: Bool = true, maxChars: Int = 120) {
        self.machine = HudStateMachine(maxChars: maxChars)
        self.position = position
        self.sounds = sounds
        self.model.showDraft = showDraft
    }

    /// Hot-apply a reloaded `[hud]` section.
    func applyConfig(enabled: Bool, position: String, showDraft: Bool, sounds: Bool, maxChars: Int) {
        self.enabled = enabled
        self.position = position
        self.sounds = sounds
        self.model.showDraft = showDraft
        self.machine.maxChars = maxChars
    }

    /// Build the panel ahead of first use (no construction cost inside a dictation).
    func prepare() {
        guard panel == nil, !panelFailed else { return }
        ensurePanel()
    }

    /// Mark the panel's window-server window as suspect (sleep/wake). The next
    /// present() while hidden swaps in a fresh panel — same recovery the event
    /// tap (#49) and audio engine (#60) already get on wake.
    func markStale() { panelStale = true }

    /// The `HudBus` render callback — drained payloads in, panel updated. Main thread.
    func render(_ payloads: [UiEvent: HudPayload]) {
        let now = CACurrentMediaTime()
        var vm = machine.apply(payloads, now: now)
        if !enabled {
            // Disabled: force hidden so the panel never shows (mirrors `Hud.enabled`).
            vm = HudViewModel()
        }
        present(vm, now: now)
    }

    private func present(_ vm: HudViewModel, now: Double) {
        if hudShouldRebuildStale(stale: panelStale, prevState: prevState) {
            panelStale = false
            if panel != nil {
                NSLog("hud: rebuilding stale panel after wake")
                rebuildPanel()
            }
        }
        if panel == nil && !panelFailed { ensurePanel() }
        guard let panel else { return }

        // Fresh recording session: drop any stale draft/waveform.
        if vm.state == "recording" && prevState != "recording" {
            displayedDraft = ""
            history.reset()
            model.bars = history.bars()
            model.stableDraft = ""
            model.volatileDraft = ""
        }

        if vm.visible {
            playSoundOnEntry(vm.state)
            updateModel(vm)
            updateWaveformTimer(recording: vm.state == "recording")
            if hudShouldShow(state: vm.state, prevState: prevState) { show(panel) }
        } else {
            updateWaveformTimer(recording: false)
            if prevState != "hidden" { hide(panel) }
        }
        prevState = vm.state
        model.vm = vm

        // Schedule the hide tick (a stale tick is harmless — it only hides past
        // an unexpired deadline).
        hideTimer?.invalidate()
        hideTimer = nil
        if let hideAt = vm.hideAt {
            let delay = max(0.0, hideAt - now) + 0.01
            hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func tick() {
        guard let panel else { return }
        let vm = machine.tick(now: CACurrentMediaTime())
        if !vm.visible && prevState != "hidden" {
            updateWaveformTimer(recording: false)
            hide(panel)
        }
        prevState = vm.state
        model.vm = vm
    }

    private func updateModel(_ vm: HudViewModel) {
        if vm.state == "recording" && model.showDraft {
            let (stable, delta) = splitStablePrefix(displayedDraft, vm.draft)
            model.stableDraft = stable
            model.volatileDraft = delta
            displayedDraft = vm.draft
        }
        currentLevel = vm.level
    }

    // MARK: - waveform sampling (only while recording)

    private func updateWaveformTimer(recording: Bool) {
        if recording && waveTimer == nil {
            history.reset()
            waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.history.push(self.currentLevel)
                    self.model.bars = self.history.bars()
                }
            }
        } else if !recording, let t = waveTimer {
            t.invalidate()
            waveTimer = nil
        }
    }

    // MARK: - sounds

    private func playSoundOnEntry(_ state: String) {
        guard sounds, state != prevState, let name = HudConst.stateSounds[state] else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - panel lifecycle

    private func ensurePanel() {
        // Drop any observer from a previous panel before building a new one:
        // NotificationCenter retains block observers strongly and `deinit` only
        // removes the last, so a panel rebuild (e.g. a future orderFront
        // self-heal) would otherwise leak the prior observer and keep firing it.
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        let size = HudConst.pillSize
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false       // default true vanishes accessory HUDs
        panel.level = .statusBar                // after styleMask: mask can reset it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0.0

        let hosting = NSHostingView(rootView: HudView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        panel.contentView = hosting
        self.panel = panel

        // Seed visibility from the panel's actual occlusion at creation rather
        // than assuming visible: a panel built while occluded (background launch,
        // display off) then wouldn't animate a shimmer until the first occlusion
        // callback arrives. A freshly-built, not-yet-ordered-front panel reads
        // not-visible, which is correct — show() flips it true when it appears.
        model.windowVisible = panel.occlusionState.contains(.visible)

        // Track on-screen occlusion so the shimmer's repeatForever sweep pauses
        // when the pill isn't visible (Space switch, display sleep, ordered
        // out) — an idle HUD must not keep redrawing at the refresh rate.
        // Capture the panel and model weakly (not via a strong self): the
        // observer must never extend either's lifetime past HudController.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model, let panel = self.panel else { return }
                model.windowVisible = panel.occlusionState.contains(.visible)
            }
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

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
        // The pill is now front; mark it visible immediately so a shimmer shown
        // this cycle animates without waiting for the first occlusion callback
        // (which can lag the order-front). Occlusion updates take over after.
        model.windowVisible = true
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
}
