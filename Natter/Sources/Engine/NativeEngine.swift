import ApplicationServices
import Foundation
import SwiftUI

/// The native dictation engine, off by default behind the "Native engine (beta)"
/// toggle. M5 adds the live UX the Python HUD has: a never-steals-focus NSPanel
/// HUD with two-tone streaming drafts (incremental re-transcription on a ~1 s
/// cadence — M0 Result 2), a waveform and a VAD silence arc, hands-free mode
/// (Fn+Space), energy-based auto-stop, and Esc-cancel. M6 wires in the cleanup
/// LLM: STT stays on the ANE, Qwen3 cleanup runs on the now-free GPU between
/// transcribe and paste when `[cleanup] enabled`, falling back to the raw
/// transcript on timeout/rejection/error — the raw <300 ms paste path is
/// untouched when cleanup is off. Mutual exclusion with the Python engine is
/// enforced by the pidfile.
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
    private let cleanup = CleanupEngine()
    private var tap: EventTap?
    private let configPath: String

    // [cleanup] snapshot, read at arm() like [hud]/[vad] (re-arm to apply).
    // Defaults mirror SettingsStore/config.py.
    private var cleanupEnabled = true
    private var cleanupStyle = "polish"
    private var cleanupTimeoutS = 5.0
    private var cleanupModelID = "mlx-community/Qwen3-4B-4bit"
    // STT model id, snapshotted at arm() for the (anonymous) dictation_completed
    // telemetry event — the basename only ever reaches the wire.
    private var sttModelID = "mlx-community/parakeet-tdt-0.6b-v3"

    // [history] snapshot + store (M7a: the native engine writes the rows).
    // Opens at arm(), closes at disarm(); enabled=false writes nothing.
    private var historyEnabled = true
    private var historyRetentionDays = 7
    private var history: HistoryStore?

    // [dictionary] snapshot (Phase 4), read at arm() like [cleanup]. `words`
    // feed the cleanup prompt prefix (re-arm to apply); `replacements` post-fix
    // the final text just before paste, even when cleanup is off/timed out.
    private var dictionary = NatterDictionary(words: [], replacements: [])

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

    /// The Setup checklist's "tap really works" probe: an Input Monitoring
    /// grant doesn't reach an already-running process (relaunch note).
    var tapInstalled: Bool { tap != nil }

    /// One engine per process — the AppDelegate auto-arms it at launch and the
    /// scenes observe it, so both need the same instance.
    static let shared = NativeEngine()

    // MARK: - arm / disarm (Settings/menu toggle, or the silent launch path)

    /// `interactive: false` is the launch auto-arm (M7a): never prompt, never
    /// dialog-storm a fresh login — a missing grant degrades to a menu-bar
    /// badge whose fix path is the Setup pane.
    func arm(interactive: Bool = true) async {
        guard !isArmed else { return }
        if let holder = pidfile.acquire("native") {
            NSLog("natter-engine: blocked by %@ engine", holder.name)
            status = .blocked(
                "Natter's \(holder.name) engine is running — quit it before enabling the native engine.")
            TelemetryClient.shared.emit(.error, props: errorProps("engine_blocked"))
            return
        }
        if interactive {
            let axTrusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            NSLog("natter-engine: arm() begin — AX trusted=%@", axTrusted ? "yes" : "no")
        } else {
            guard Permissions.allGranted() else {
                NSLog("natter-engine: auto-arm skipped — permissions missing")
                pidfile.release()
                status = .failed("Permissions needed — open Setup to finish enabling Natter.")
                TelemetryClient.shared.emit(.error, props: errorProps("permissions_missing"))
                return
            }
            NSLog("natter-engine: auto-arm — all grants present")
        }
        status = .preparing

        loadEngineConfig()

        // History store (M7a): the engine process holds the pidfile, so it is
        // the single inserter. A failed open degrades to no-history — the
        // engine must dictate even when bookkeeping can't.
        if historyEnabled {
            history = HistoryStore(
                path: HistoryReader.defaultPath(), retentionDays: historyRetentionDays)
            if history == nil { NSLog("history: store failed to open — history disabled") }
        }

        do {
            try await transcriber.prepare()
            NSLog("natter-engine: model ready")
        } catch {
            NSLog("natter-engine: model load FAILED: %@", String(describing: error))
            pidfile.release()
            history?.close(); history = nil
            status = .failed("Speech model failed to load. \(error.localizedDescription)")
            TelemetryClient.shared.emit(.error, props: errorProps("model_load_failed"))
            return
        }

        // The cleanup LLM loads + warms in the background (first run downloads
        // ~2.3 GB): arm→ready never waits on it. Until it's ready, clean()
        // returns nil and the raw transcript pastes — Python's exact behavior.
        if cleanupEnabled {
            let modelID = cleanupModelID
            let hint = dictionary.hint  // baked into the cached prefix — set before prepare
            Task { [cleanup] in
                await cleanup.setTermsHint(hint)
                await cleanup.prepare(modelID: modelID)
            }
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
            NSLog("natter-engine: event tap installed")
        } catch {
            NSLog("natter-engine: event tap FAILED (Input Monitoring?): %@", String(describing: error))
            pidfile.release()
            history?.close(); history = nil
            status = .failed(
                "Input Monitoring isn't granted. Enable Natter in System Settings ▸ Privacy & "
                + "Security ▸ Input Monitoring, then turn this on again.")
            TelemetryClient.shared.emit(.error, props: errorProps("input_monitoring_denied"))
            return
        }
        self.tap = tap
        persist(true)
        NSLog("natter-engine: ARMED — ready")
        status = .ready
        TelemetryClient.shared.emit(.appLaunch)
    }

    /// One enum-shaped code, never a message (the contract forbids free text).
    private nonisolated func errorProps(_ code: String) -> TelemetryProps {
        var p = TelemetryProps(); p.errorCode = code; return p
    }

    func disarm() {
        tap?.stop(); tap = nil
        draftTask?.cancel(); draftTask = nil
        endVadSession()
        capture.stop()
        capture.onBlock = nil
        // Unlike the ~600 MB Parakeet models (kept for fast re-arm), the
        // ~2.3 GB cleanup LLM is dropped on toggle-off; re-arm reloads in ~1.5s.
        Task { [cleanup] in await cleanup.unload() }
        bus.post(.state("idle", "ready"))   // hide the HUD if showing
        history?.close(); history = nil
        pidfile.release()
        resetMachine()
        persist(false)
        status = .off
    }

    /// Read `[hud]`/`[vad]`/`[cleanup]` from config.toml (defaults match
    /// `config.py`) and build the HUD config + the energy-only endpointer.
    private func loadEngineConfig() {
        let doc = ConfigDocument.load(path: configPath)
        let hudEnabled = doc.bool("hud", "enabled") ?? true
        hud.applyConfig(
            enabled: hudEnabled,
            position: doc.string("hud", "position") ?? "bottom-center",
            showDraft: doc.bool("hud", "show_draft") ?? true,
            sounds: doc.bool("hud", "sounds") ?? true,
            maxChars: doc.int("hud", "max_chars") ?? 120)
        hud.prepare()

        sttModelID = doc.string("stt", "model") ?? "mlx-community/parakeet-tdt-0.6b-v3"
        cleanupEnabled = doc.bool("cleanup", "enabled") ?? true
        cleanupStyle = doc.string("cleanup", "style") ?? "polish"
        cleanupTimeoutS = doc.double("cleanup", "timeout_s") ?? 5.0
        cleanupModelID = doc.string("cleanup", "model") ?? "mlx-community/Qwen3-4B-4bit"

        historyEnabled = doc.bool("history", "enabled") ?? true
        historyRetentionDays = doc.int("history", "retention_days") ?? 7

        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        dictionary = NatterDictionary(
            words: doc.stringArray("dictionary", "words") ?? [],
            replacements: doc.stringTable("dictionary.replacements").map { ($0.key, $0.value) },
            enabled: dictEnabled)

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
            NSLog("natter-engine: vad stale endpoint (gen %d != %d)", generation, sessionGen)
            return
        }
        machineLock.lock()
        let stopped = machine.externalStop()
        if stopped { stopAt = CFAbsoluteTimeGetCurrent() }  // t0 = auto-stop
        machineLock.unlock()
        if stopped {
            NSLog("natter-engine: vad natural pause — auto-stop")
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
                NSLog("natter-engine: hands-free — VAD armed (gen %d)", sessionGen)
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
            NSLog("natter-engine: capture started (Fn down)")
            bus.post(.state("recording", "recording (\(mode))"))
            startDraftLoop()
            status = .recording
        } catch {
            NSLog("natter-engine: capture FAILED (Microphone?): %@", String(describing: error))
            bus.post(.state("idle", "ready"))
            status = .failed(
                "Microphone unavailable. Grant it in System Settings ▸ Privacy & Security ▸ Microphone.")
            TelemetryClient.shared.emit(.error, props: errorProps("microphone_unavailable"))
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
        NSLog("natter-engine: stop — %d samples (%.1fs), transcribing", samples.count,
              Double(samples.count) / 16000)
        // Snapshot on the main actor; the Task below runs off it.
        let doCleanup = cleanupEnabled
        let style = cleanupStyle
        let timeoutS = cleanupTimeoutS
        let store = history
        let dict = dictionary
        let durationS = Double(samples.count) / 16000.0
        let sttModel = sttModelID
        Task { [weak self] in
            guard let self else { return }
            // Stage timings mirror bench.py (t0 = key-up/auto-stop); they land
            // in history.timings_json with Python's keys.
            var timings = EngineTimings()
            timings.start(at: t0)
            let raw = (try? await self.transcriber.transcribe(samples)) ?? ""
            timings.stamp("stt_finalize")
            NSLog("natter-engine: transcript = %@", raw.isEmpty ? "<empty>" : raw)
            var text = raw
            var cleanupStatus: CleanupStatus?
            // Cleanup OFF: nothing below runs — the <300 ms raw path is intact.
            // The draft loop is already stopped (`finishing`), so the GPU pass
            // never overlaps STT on the ANE.
            if doCleanup, !raw.isEmpty {
                self.bus.post(.state("polishing", ""))
                let (cleaned, status) = await self.cleanupWithWatchdog(
                    raw: raw, style: style, timeoutS: timeoutS)
                text = cleaned
                cleanupStatus = status
                timings.stamp("cleanup")
                if status != .ok {
                    NSLog("natter-engine: cleanup %@ — pasting raw", status.rawValue)
                }
            }
            // Custom-word fixups run last so a misheard proper noun is corrected
            // whether cleanup polished the text, fell back to raw, or is off
            // (mirrors app.py). `final_text` stored in history reflects them.
            text = dict.apply(text)
            let (appHint, pastedAt): (String?, Double?) = await MainActor.run {
                guard !text.isEmpty else {
                    self.bus.post(.result("empty", ""))
                    self.doneMachine()
                    self.status = .ready
                    return (nil, nil)
                }
                // app_hint = whatever is frontmost when the paste lands.
                let hint = NSWorkspace.shared.frontmostApplication?.localizedName
                self.lastTranscript = text  // retained for recovery before the paste
                let outcome = Paster.paste(text)
                let pasteT = CFAbsoluteTimeGetCurrent()
                self.lastPasteMs = (pasteT - t0) * 1000
                var pastedAt: Double?
                switch outcome {
                case .pasted:
                    pastedAt = pasteT
                    self.bus.post(.result("ok", text))
                    NSLog("engine: paste %.0fms (%d chars)", self.lastPasteMs ?? 0, text.count)
                case .copiedToClipboard:
                    // No editable field had focus — the transcript is on the
                    // clipboard, not lost. Tell the user via the HUD flash.
                    self.bus.post(.result("error", "copied to clipboard"))
                    NSLog("engine: no focused field — left %d chars on the clipboard", text.count)
                }
                self.doneMachine()
                self.status = .ready
                return (hint, pastedAt)
            }
            // Anonymous telemetry, emitted here for the same reason history is —
            // strictly after the paste, off the latency path. Fire-and-forget;
            // a true no-op unless the user opted in. Never any text.
            if !text.isEmpty {
                var props = TelemetryProps()
                props.durationMs = Int(durationS * 1000)
                props.sttModel = sttModel
                props.cleanup = doCleanup
                props.cleanupStatus = cleanupStatus?.rawValue ?? "off"
                TelemetryClient.shared.emit(.dictationCompleted, props: props)
                if doCleanup {
                    var used = TelemetryProps()
                    used.cleanup = true
                    used.cleanupStatus = cleanupStatus?.rawValue ?? "off"
                    TelemetryClient.shared.emit(.cleanupUsed, props: used)
                }
            }

            // History row, strictly after the paste and the ready flip — a
            // ~1 ms INSERT on this now-idle task, never on the latency path.
            // Python records even when the insert failed (the words must not
            // be lost from history too) but only stamps "insert" on success.
            if let store, !text.isEmpty {
                if let pastedAt { timings.stamp("insert", at: pastedAt) }
                let now = Date().timeIntervalSince1970
                store.add(
                    ts: now, rawText: raw, finalText: text,
                    cleanupStatus: cleanupStatus?.rawValue ?? "off",
                    appHint: appHint, durationS: durationS,
                    timingsJson: timings.json())
                store.purge(now: now)
                NotificationCenter.default.post(name: .natterHistoryDidChange, object: nil)
            }
        }
    }

    /// Race the cleanup against `timeout_s` plus a grace period. The per-chunk
    /// deadline inside `clean()` is authoritative, but a Metal kernel that
    /// hangs without ever yielding a chunk would never reach it — the paste
    /// must not be held hostage. First result wins; a late one is discarded
    /// (the zombie generation can only delay the *next* cleanup, never STT,
    /// which runs on the ANE).
    private nonisolated func cleanupWithWatchdog(
        raw: String, style: String, timeoutS: Double
    ) async -> (String, CleanupStatus) {
        await withTaskGroup(of: Optional<(String, CleanupStatus)>.self) { group in
            group.addTask { [cleanup] in
                await runCleanup(cleanup, text: raw, style: style, timeoutS: timeoutS)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64((timeoutS + 2.0) * 1_000_000_000))
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first ?? (raw, .timeout)
        }
    }

    private func cancelRecording() {
        NSLog("natter-engine: cancelled by user")
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
