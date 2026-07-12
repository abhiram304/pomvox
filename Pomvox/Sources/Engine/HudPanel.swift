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

        // Track on-screen occlusion so the shimmer's repeatForever sweep pauses
        // when the pill isn't visible (Space switch, display sleep, ordered
        // out) — an idle HUD must not keep redrawing at the refresh rate.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                self.model.windowVisible = panel.occlusionState.contains(.visible)
            }
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

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
        // The pill is now front; mark it visible immediately so a shimmer shown
        // this cycle animates without waiting for the first occlusion callback
        // (which can lag the order-front). Occlusion updates take over after.
        model.windowVisible = true
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
}
