import AVFoundation
import FluidAudio
import Foundation

enum TranscriberError: Error { case notLoaded }

/// The STT half of a cold-start breakdown (item 3), returned by `prepare()`.
/// `alreadyLoaded` marks a warm re-arm where nothing loaded, so the engine can
/// skip emitting a bogus all-zero cold-start event.
struct SttLoadTiming: Sendable {
    var weightLoadMs: Double = 0
    var coremlCompileMs: Double = 0
    var aneWarmupMs: Double = 0
    var alreadyLoaded: Bool = false
}

/// Thread-safe marker for the download→compile transition. FluidAudio's progress
/// callback fires on an arbitrary queue; we note the instant `downloading` flips
/// false (bytes down, CoreML compiling) so weight-load and compile time separate.
private final class LoadPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var sawDownload = false
    private var compileStartAt: Double?

    func note(downloading: Bool, now: Double) {
        lock.lock(); defer { lock.unlock() }
        if downloading {
            sawDownload = true
        } else if sawDownload, compileStartAt == nil {
            compileStartAt = now
        }
    }

    /// (whether any download happened, when compile began if it did).
    func snapshot() -> (downloaded: Bool, compileStartAt: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (sawDownload, compileStartAt)
    }
}

/// FluidAudio Parakeet TDT 0.6b on the Neural Engine (M0 result 1: PASS,
/// 3–8× the GPU path); the version (v3 default, v2 selectable) comes from
/// `[stt] model`. Reuses the `native/` bench's load + transcribe pattern.
/// Models load + warm on toggle-on (off the hot path); on release the whole
/// utterance is batch-transcribed (not streaming — that's M5).
///
/// An `actor` so model access is serialized and never blocks the main thread.
actor Transcriber {
    private var asr: AsrManager?
    private var loadedModel: SttModel?
    private var decoderLayers = 0

    var isLoaded: Bool { asr != nil }

    /// Download (first run only, ~97 s), load, and warm the model. Idempotent
    /// *for the same model*: a no-op when `model` is already loaded (fast
    /// re-arm), but when `[stt] model` changed and the engine re-armed, the
    /// previously-loaded version is torn down and the new one loaded — otherwise
    /// the cached model keeps running while the logs/telemetry report the newly
    /// resolved one.
    /// `onProgress` reports `(fraction, downloading)` while the ~460 MB first-run
    /// fetch is in flight — `downloading` flips false once the bytes are down and
    /// CoreML is compiling — so the UI can show a live percentage instead of a
    /// silent "Preparing…". `model` is resolved from `[stt] model` (defaults to
    /// the shipped v3) — the loader picks the matching FluidAudio version.
    @discardableResult
    func prepare(
        model: SttModel = .default,
        onProgress: (@Sendable (Double, Bool) -> Void)? = nil
    ) async throws -> SttLoadTiming {
        if asr != nil, loadedModel == model { return SttLoadTiming(alreadyLoaded: true) }
        // Switching models: free the old CoreML graph before loading the new
        // one so we don't hold both resident (~600 MB each) on low-RAM Macs.
        await asr?.cleanup()
        asr = nil
        loadedModel = nil

        // Split weight fetch (network) from CoreML compile/load: the phase
        // marker records when the download callback stops reporting bytes.
        let phase = LoadPhase()
        let loadStart = CFAbsoluteTimeGetCurrent()
        let models = try await AsrModels.downloadAndLoad(version: model.fluidVersion) { progress in
            let downloading: Bool
            if case .downloading = progress.phase { downloading = true } else { downloading = false }
            phase.note(downloading: downloading, now: CFAbsoluteTimeGetCurrent())
            onProgress?(progress.fractionCompleted, downloading)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        decoderLayers = await manager.decoderLayerCount
        asr = manager
        loadedModel = model
        let loadEnd = CFAbsoluteTimeGetCurrent()

        // Warm the ANE so the first real utterance hits the fast path.
        let warmStart = CFAbsoluteTimeGetCurrent()
        _ = try? await transcribe([Float](repeating: 0, count: 16000))
        let warmEnd = CFAbsoluteTimeGetCurrent()

        let (downloaded, compileStartAt) = phase.snapshot()
        var timing = SttLoadTiming(alreadyLoaded: false)
        if downloaded, let compileStartAt {
            timing.weightLoadMs = (compileStartAt - loadStart) * 1000
            timing.coremlCompileMs = (loadEnd - compileStartAt) * 1000
        } else {
            // No network fetch this launch (warm byte cache): the whole load is
            // the CoreML compile/load stage — large here means the compiled
            // graph wasn't reused.
            timing.weightLoadMs = 0
            timing.coremlCompileMs = (loadEnd - loadStart) * 1000
        }
        timing.aneWarmupMs = (warmEnd - warmStart) * 1000
        return timing
    }

    /// Batch-transcribe 16 kHz mono samples; returns the raw transcript.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { throw TranscriberError.notLoaded }
        // Write a temp WAV and use FluidAudio's URL path — the exact shape the
        // M0 bench proved (its AudioConverter normalizes internally). The write
        // is a few ms; transcription itself is ~0.13–0.30 s on the ANE.
        let url = try Self.writeWav(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(url, decoderState: &state)
        return result.text
    }

    private static func writeWav(_ samples: [Float], sampleRate: Double = 16000) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-utt-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(max(samples.count, 1))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
        return url
    }
}
