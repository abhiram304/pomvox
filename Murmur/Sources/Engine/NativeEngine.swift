import ApplicationServices
import Foundation
import SwiftUI

/// The native dictation engine (M4 walking skeleton), off by default behind the
/// "Native engine (beta)" toggle. Wires the ported `HotkeyMachine` to a Fn
/// push-to-talk CGEventTap, 16 kHz capture, FluidAudio batch STT on the ANE, and
/// the shared `Paster`. Cleanup is OFF this milestone — it pastes the raw
/// transcript (< 300 ms post-release budget). Mutual exclusion with the Python
/// engine is enforced by the pidfile.
///
/// Threading: the hotkey path runs on the event-tap thread (serialized by
/// `machineLock`); everything that touches UI or the audio/STT stack runs on the
/// main actor.
@MainActor
final class NativeEngine: ObservableObject {
    enum Status: Equatable {
        case off
        case preparing
        case ready
        case recording
        case transcribing
        case blocked(String)   // another engine holds the tap
        case failed(String)    // a grant is missing or the model failed to load
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastPasteMs: Double?

    // Hotkey path — touched on the event-tap thread, serialized by the lock.
    private nonisolated(unsafe) let machine: HotkeyMachine
    private nonisolated let machineLock = NSLock()
    private nonisolated(unsafe) var stopAt: CFAbsoluteTime = 0  // t0 for paste latency

    private let pidfile = Pidfile()
    private let capture = AudioCapture()
    private let transcriber = Transcriber()
    private var tap: EventTap?
    private let configPath: String

    init(configPath: String = SettingsModel.defaultPath()) {
        self.configPath = configPath
        self.machine = try! HotkeyMachine()  // M4: fixed Fn push-to-talk bindings
    }

    var isArmed: Bool {
        switch status {
        case .off, .blocked, .failed: return false
        default: return true
        }
    }

    // MARK: - arm / disarm (driven by the Settings toggle)

    func arm() async {
        guard !isArmed else { return }
        // Mutual exclusion — refuse if the Python engine (or another instance)
        // holds the tap/mic.
        if let holder = pidfile.acquire("native") {
            NSLog("murmur-engine: blocked by %@ engine", holder.name)
            status = .blocked(
                "Murmur's \(holder.name) engine is running — quit it before enabling the native engine.")
            return
        }
        // Nudge the Accessibility grant — the synthesized ⌘V paste needs it and
        // otherwise no-ops silently. macOS shows the prompt once if not trusted.
        let axTrusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSLog("murmur-engine: arm() begin — AX trusted=%@", axTrusted ? "yes" : "no")
        status = .preparing
        do {
            try await transcriber.prepare()
            NSLog("murmur-engine: model ready")
        } catch {
            NSLog("murmur-engine: model load FAILED: %@", String(describing: error))
            pidfile.release()
            status = .failed("Speech model failed to load. \(error.localizedDescription)")
            return
        }
        let tap = EventTap(
            onModifier: { [weak self] keycode, isDown in
                self?.decide { $0.onModifier(keycode, isDown) } ?? HotkeyMachine.Decision()
            },
            onKeyDown: { [weak self] keycode in
                self?.decide { $0.onKeyDown(keycode) } ?? HotkeyMachine.Decision()
            })
        do {
            try tap.start()
            NSLog("murmur-engine: event tap installed")
        } catch {
            NSLog("murmur-engine: event tap FAILED (Input Monitoring?): %@", String(describing: error))
            pidfile.release()
            status = .failed(
                "Input Monitoring isn't granted. Enable Murmur in System Settings ▸ Privacy & "
                + "Security ▸ Input Monitoring, then turn this on again.")
            return
        }
        self.tap = tap
        persist(true)
        NSLog("murmur-engine: ARMED — ready")
        status = .ready
    }

    func disarm() {
        tap?.stop(); tap = nil
        capture.stop()
        pidfile.release()
        resetMachine()
        persist(false)
        status = .off
    }

    // MARK: - hotkey path (event-tap thread)

    /// Run a HotkeyMachine transition under the lock and forward the action to
    /// the main actor. Returns the `Decision` synchronously so the tap can
    /// swallow keys when asked.
    private nonisolated func decide(
        _ body: (HotkeyMachine) -> HotkeyMachine.Decision
    ) -> HotkeyMachine.Decision {
        machineLock.lock()
        let decision = body(machine)
        if decision.action == .stop { stopAt = CFAbsoluteTimeGetCurrent() }  // t0 = Fn-up
        machineLock.unlock()
        if decision.action != .none {
            let action = decision.action
            Task { @MainActor [weak self] in self?.handle(action) }
        }
        return decision
    }

    // MARK: - actions (main actor)

    private func handle(_ action: HotkeyMachine.Action) {
        switch action {
        case .startPTT:
            startCapture()
        case .enterToggle:
            status = .recording  // hands-free: keep recording (stop via fn tap / fn+space)
        case .stop:
            finish()
        case .cancel:
            capture.stop()
            doneMachine()
            status = .ready
        case .none:
            break
        }
    }

    private func startCapture() {
        do {
            try capture.start()
            NSLog("murmur-engine: capture started (Fn down)")
            status = .recording
        } catch {
            NSLog("murmur-engine: capture FAILED (Microphone?): %@", String(describing: error))
            status = .failed(
                "Microphone unavailable. Grant it in System Settings ▸ Privacy & Security ▸ Microphone.")
            resetMachine()
        }
    }

    private func finish() {
        status = .transcribing
        let samples = capture.stop()
        machineLock.lock(); let t0 = stopAt; machineLock.unlock()
        NSLog("murmur-engine: Fn up — %d samples (%.1fs), transcribing", samples.count,
              Double(samples.count) / 16000)
        Task { [weak self] in
            guard let self else { return }
            let text = (try? await self.transcriber.transcribe(samples)) ?? ""
            NSLog("murmur-engine: transcript = %@", text.isEmpty ? "<empty>" : text)
            await MainActor.run {
                if !text.isEmpty {
                    Paster.paste(text)
                    self.lastPasteMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    self.lastTranscript = text
                    NSLog("engine: paste %.0fms (%d chars)", self.lastPasteMs ?? 0, text.count)
                }
                self.doneMachine()
                self.status = .ready
            }
        }
    }

    private func doneMachine() { machineLock.lock(); machine.done(); machineLock.unlock() }
    private func resetMachine() { machineLock.lock(); machine.reset(); machineLock.unlock() }

    /// Persist the toggle to `config.toml [engine] native` so it's a visible,
    /// greppable config value (open-source-first). The Hub owns this key; the
    /// Python engine ignores it. Comment-preserving, touches only this key.
    private func persist(_ enabled: Bool) {
        var doc = ConfigDocument.load(path: configPath)
        doc.set("engine", "native", bool: enabled)
        try? doc.write(to: configPath)
    }
}
