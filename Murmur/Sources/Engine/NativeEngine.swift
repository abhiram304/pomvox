import ApplicationServices
import Foundation
import SwiftUI

/// The native dictation engine, off by default behind the "Native engine (beta)"
/// toggle. M5 adds the live UX the Python HUD has: a never-steals-focus NSPanel
/// HUD with two-tone streaming drafts (incremental re-transcription on a ~1 s
/// cadence — M0 Result 2), a waveform and a VAD silence arc, hands-free mode
/// (Fn+Space), energy-based auto-stop, and Esc-cancel. STT stays on the ANE;
/// cleanup is OFF (M6) — it still pastes the raw transcript. Mutual exclusion
/// with the Python engine is enforced by the pidfile.
///
/// Threading: the hotkey path runs on the event-tap thread (serialized by
/// `machineLock`); the audio callback posts level/VAD via the thread-safe
/// `HudBus` (and a single MainActor hop for the auto-stop action); everything
/// that touches the HUD, the audio/STT stack, or `@Published` state runs on the
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

    // HUD + bus (the bus is thread-safe; its drain renders on the main actor).
    private let hud: HudController
    private nonisolated let bus: HudBus

    // VAD endpointer — armed only in hands-free mode. Touched on the audio thread
    // (`process`) and the main actor (`arm`/`disarm`); guarded by `vadLock`.
    private nonisolated let vadLock = NSLock()
    private nonisolated(unsafe) var endpointer: Endpointer?
    private var vadEnabled = false

    // Session generation: bumped on every start/stop so a stale VAD endpoint
    // queued across sessions is a no-op (mirrors app.py `_session_gen`). Only the
    // main actor mutates it; the audio thread reads the endpointer's stamped copy.
    private var sessionGen = 0

    // Incremental re-transcription draft loop.
    private var draftTask: Task<Void, Never>?
    private var draftInFlight = false
    private var finishing = false

    init(configPath: String = SettingsModel.defaultPath()) {
        self.configPath = configPath
        self.machine = try! HotkeyMachine()  // fixed Fn push-to-talk bindings
        let hud = HudController()
        self.hud = hud
        self.bus = HudBus(render: { payloads in
            // The default schedule already runs on the main thread.
            MainActor.assumeIsolated { hud.render(payloads) }
        })
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
        if let holder = pidfile.acquire("native") {
            NSLog("murmur-engine: blocked by %@ engine", holder.name)
            status = .blocked(
                "Murmur's \(holder.name) engine is running — quit it before enabling the native engine.")
            return
        }
        let axTrusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSLog("murmur-engine: arm() begin — AX trusted=%@", axTrusted ? "yes" : "no")
        status = .preparing

        loadHudAndVadConfig()

        do {
            try await transcriber.prepare()
            NSLog("murmur-engine: model ready")
        } catch {
            NSLog("murmur-engine: model load FAILED: %@", String(describing: error))
            pidfile.release()
            status = .failed("Speech model failed to load. \(error.localizedDescription)")
            return
        }

        // The audio callback posts mic level (waveform) and, when armed, drives
        // the VAD endpointer. Set before any capture.start().
        capture.onBlock = { [weak self] block in self?.onAudioBlock(block) }

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
        draftTask?.cancel(); draftTask = nil
        endVadSession()
        capture.stop()
        capture.onBlock = nil
        bus.post(.state("idle", "ready"))   // hide the HUD if showing
        pidfile.release()
        resetMachine()
        persist(false)
        status = .off
    }

    /// Read `[hud]`/`[vad]` from config.toml (defaults match `config.py`) and build
    /// the HUD config + the energy-only endpointer.
    private func loadHudAndVadConfig() {
        let doc = ConfigDocument.load(path: configPath)
        let hudEnabled = doc.bool("hud", "enabled") ?? true
        hud.applyConfig(
            enabled: hudEnabled,
            position: doc.string("hud", "position") ?? "bottom-center",
            showDraft: doc.bool("hud", "show_draft") ?? true,
            sounds: doc.bool("hud", "sounds") ?? true,
            maxChars: doc.int("hud", "max_chars") ?? 120)
        hud.prepare()

        vadEnabled = doc.bool("vad", "enabled") ?? true
        let detector = EndpointDetector(
            silenceMs: doc.int("vad", "silence_ms") ?? 2000,
            minSpeechMs: doc.int("vad", "min_speech_ms") ?? 250,
            frameMs: 30,
            energyGateDbfs: doc.double("vad", "energy_gate_dbfs") ?? -45.0)
        let ep = Endpointer(backend: EnergyGateBackend(), detector: detector,
                            maxSessionS: doc.double("vad", "max_session_s") ?? 600.0)
        vadLock.lock(); endpointer = ep; vadLock.unlock()
    }

    // MARK: - hotkey path (event-tap thread)

    private nonisolated func decide(
        _ body: (HotkeyMachine) -> HotkeyMachine.Decision
    ) -> HotkeyMachine.Decision {
        machineLock.lock()
        let decision = body(machine)
        if decision.action == .stop { stopAt = CFAbsoluteTimeGetCurrent() }  // t0 = key-up
        machineLock.unlock()
        if decision.action != .none {
            let action = decision.action
            Task { @MainActor [weak self] in self?.handle(action) }
        }
        return decision
    }

    // MARK: - audio callback (audio thread)

    private nonisolated func onAudioBlock(_ block: [Float]) {
        bus.post(.level(level01(blockDbfs(block))))
        vadLock.lock()
        guard let ep = endpointer, ep.armed else { vadLock.unlock(); return }
        let (event, fraction) = ep.process(block)
        let gen = ep.generation
        vadLock.unlock()
        if let fraction { bus.post(.endpointProgress(fraction)) }
        switch event {
        case .endpoint:
            Task { @MainActor [weak self] in self?.onVadEndpoint(gen) }
        case .capWarning:
            bus.post(.state("recording", "recording — time limit soon"))
        case .speechStart, nil:
            break
        }
    }

    /// Main actor. The generation check makes a stale endpoint queued across
    /// sessions a no-op; `externalStop()` makes it a no-op in any state but TOGGLE.
    private func onVadEndpoint(_ generation: Int) {
        guard generation == sessionGen else {
            NSLog("murmur-engine: vad stale endpoint (gen %d != %d)", generation, sessionGen)
            return
        }
        machineLock.lock()
        let stopped = machine.externalStop()
        if stopped { stopAt = CFAbsoluteTimeGetCurrent() }  // t0 = auto-stop
        machineLock.unlock()
        if stopped {
            NSLog("murmur-engine: vad natural pause — auto-stop")
            finish()
        }
    }

    // MARK: - actions (main actor)

    private func handle(_ action: HotkeyMachine.Action) {
        switch action {
        case .startPTT:
            startCapture(mode: "push-to-talk")
        case .enterToggle:
            // Hands-free: keep recording, arm the energy endpointer.
            bus.post(.state("recording", "recording (hands-free)"))
            if vadEnabled {
                vadLock.lock(); endpointer?.arm(generation: sessionGen); vadLock.unlock()
                NSLog("murmur-engine: hands-free — VAD armed (gen %d)", sessionGen)
            }
            status = .recording
        case .stop:
            finish()
        case .cancel:
            cancelRecording()
        case .none:
            break
        }
    }

    private func startCapture(mode: String) {
        sessionGen += 1
        finishing = false
        do {
            try capture.start()
            NSLog("murmur-engine: capture started (Fn down)")
            bus.post(.state("recording", "recording (\(mode))"))
            startDraftLoop()
            status = .recording
        } catch {
            NSLog("murmur-engine: capture FAILED (Microphone?): %@", String(describing: error))
            bus.post(.state("idle", "ready"))
            status = .failed(
                "Microphone unavailable. Grant it in System Settings ▸ Privacy & Security ▸ Microphone.")
            resetMachine()
        }
    }

    private func finish() {
        finishing = true
        endVadSession()
        draftTask?.cancel(); draftTask = nil
        status = .transcribing
        bus.post(.state("transcribing", ""))
        let samples = capture.stop()
        machineLock.lock(); let t0 = stopAt; machineLock.unlock()
        NSLog("murmur-engine: stop — %d samples (%.1fs), transcribing", samples.count,
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
                    self.bus.post(.result("ok", text))
                    NSLog("engine: paste %.0fms (%d chars)", self.lastPasteMs ?? 0, text.count)
                } else {
                    self.bus.post(.result("empty", ""))
                }
                self.doneMachine()
                self.status = .ready
            }
        }
    }

    private func cancelRecording() {
        NSLog("murmur-engine: cancelled by user")
        endVadSession()
        draftTask?.cancel(); draftTask = nil
        finishing = true
        capture.stop()
        bus.post(.result("cancelled", ""))
        doneMachine()
        status = .ready
    }

    /// Invalidate any endpoint in flight and stop classifying (mirrors
    /// `app.py:_end_vad_session`).
    private func endVadSession() {
        sessionGen += 1
        vadLock.lock(); endpointer?.disarm(); vadLock.unlock()
    }

    // MARK: - incremental re-transcription draft loop

    private func startDraftLoop() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // ~1 s cadence
                if Task.isCancelled { break }
                await self?.draftTick()
            }
        }
    }

    /// Re-transcribe the accumulated session audio and push the full text to the
    /// HUD (the controller does the stable/volatile two-tone split). A full ANE
    /// re-transcribe is 0.13–0.27 s (M0), so this refreshes faster than the
    /// Python 2 s chunk cadence at batch quality. `draftInFlight` coalesces; the
    /// `finishing` flag stops new passes from racing the finalize transcribe.
    private func draftTick() async {
        guard !finishing, !draftInFlight else { return }
        let snap = capture.snapshot()
        guard snap.count >= 8000 else { return }  // ~0.5 s before a first draft
        draftInFlight = true
        let text = (try? await transcriber.transcribe(snap)) ?? ""
        draftInFlight = false
        guard !finishing, !Task.isCancelled, !text.isEmpty else { return }
        bus.post(.draft(text))
    }

    private func doneMachine() { machineLock.lock(); machine.done(); machineLock.unlock() }
    private func resetMachine() { machineLock.lock(); machine.reset(); machineLock.unlock() }

    /// Persist the toggle to `config.toml [engine] native`.
    private func persist(_ enabled: Bool) {
        var doc = ConfigDocument.load(path: configPath)
        doc.set("engine", "native", bool: enabled)
        try? doc.write(to: configPath)
    }
}
