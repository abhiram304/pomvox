import AVFoundation
import Foundation

/// Microphone capture → accumulated 16 kHz mono float32 samples. Mirrors
/// `src/natter/audio.py` capture params (SAMPLERATE=16000, mono, float32). The
/// hardware input format (usually 44.1/48 kHz) is resampled per buffer via an
/// `AVAudioConverter`; `stop()` returns the whole utterance for batch STT.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false

    /// Called on the audio thread with each converted 16 kHz block (mirrors
    /// `app.py:_on_block`). Used to post mic level and feed the VAD endpointer.
    /// Must only do reductions + coalesced posts — never touch the recorder, the
    /// pipeline, or AppKit/SwiftUI directly. Set before `start()`.
    var onBlock: (([Float]) -> Void)?

    init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16000, channels: 1, interleaved: false)!
    }

    /// Begin capture. Throws if the audio engine can't start (no mic grant /
    /// no input device).
    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); recording = true; lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop capture and return the captured 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock(); recording = false; let out = samples; samples.removeAll(); lock.unlock()
        return out
    }

    /// A non-destructive copy of the audio accumulated so far — the source for
    /// the incremental re-transcription draft loop. Distinct from `stop()`, which
    /// returns *and clears* for the finalize batch.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return }
        guard let channel = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        let block = Array(UnsafeBufferPointer(start: channel[0], count: count))
        lock.lock()
        let active = recording
        if active { samples.append(contentsOf: block) }
        lock.unlock()
        if active { onBlock?(block) }
    }
}
