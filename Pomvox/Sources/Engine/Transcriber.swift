import AVFoundation
import FluidAudio
import Foundation

enum TranscriberError: Error { case notLoaded }

/// FluidAudio Parakeet TDT 0.6b on the Neural Engine (M0 result 1: PASS,
/// 3–8× the GPU path); the version (v3 default, v2 selectable) comes from
/// `[stt] model`. Reuses the `native/` bench's load + transcribe pattern.
/// Models load + warm on toggle-on (off the hot path); on release the whole
/// utterance is batch-transcribed (not streaming — that's M5).
///
/// An `actor` so model access is serialized and never blocks the main thread.
actor Transcriber {
    private var asr: AsrManager?
    private var decoderLayers = 0

    var isLoaded: Bool { asr != nil }

    /// Download (first run only, ~97 s), load, and warm the model. Idempotent.
    /// `onProgress` reports `(fraction, downloading)` while the ~460 MB first-run
    /// fetch is in flight — `downloading` flips false once the bytes are down and
    /// CoreML is compiling — so the UI can show a live percentage instead of a
    /// silent "Preparing…". `model` is resolved from `[stt] model` (defaults to
    /// the shipped v3) — the loader picks the matching FluidAudio version.
    func prepare(
        model: SttModel = .default,
        onProgress: (@Sendable (Double, Bool) -> Void)? = nil
    ) async throws {
        if asr != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: model.fluidVersion) { progress in
            let downloading: Bool
            if case .downloading = progress.phase { downloading = true } else { downloading = false }
            onProgress?(progress.fractionCompleted, downloading)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        decoderLayers = await manager.decoderLayerCount
        asr = manager
        // Warm the ANE so the first real utterance hits the fast path.
        _ = try? await transcribe([Float](repeating: 0, count: 16000))
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
