import Foundation

/// Voice-activity detection for hands-free auto-stop — faithful port of the pure
/// logic in `src/murmur/vad.py`. The Linux-tested `tests/test_vad.py` vectors are
/// reproduced 1:1 in `VadLogicTests.swift`.
///
/// M5 ships an **energy-only** classifier: `EnergyGateBackend` always votes
/// voiced, so `EndpointDetector`'s `energyGateDbfs` AND-gate becomes the sole
/// speech decision. The `VadBackend` seam (and the frame-size-parameterized
/// `FrameSlicer`) leaves room to drop in libfvad/Silero later without a rewrite.

let vadSampleRate = 16000
private let capWarnFraction = 0.9

enum VadEvent: Equatable {
    case speechStart
    case endpoint
    case capWarning
}

/// float32 blocks in → fixed-size int16 frames out (samples, not bytes —
/// `frameDbfs` consumes the same representation). Port of `FrameSlicer`.
final class FrameSlicer {
    private let frameSamples: Int
    private var buf: [Int16] = []

    init(frameSamples: Int) { self.frameSamples = frameSamples }

    func add(_ block: [Float]) -> [[Int16]] {
        for x in block {
            let c = max(Float(-1), min(Float(1), x))
            buf.append(Int16(c * 32767.0))
        }
        var frames: [[Int16]] = []
        while buf.count >= frameSamples {
            frames.append(Array(buf[0..<frameSamples]))
            buf.removeFirst(frameSamples)
        }
        return frames
    }

    func reset() { buf.removeAll(keepingCapacity: true) }
}

/// RMS level of an int16 frame in dBFS. Port of `frame_dbfs`.
func frameDbfs(_ frame: [Int16]) -> Double {
    guard !frame.isEmpty else { return 10 * log10(1e-12) }
    var sumsq = 0.0
    for s in frame {
        let v = Double(s) / 32768.0
        sumsq += v * v
    }
    return 10 * log10(sumsq / Double(frame.count) + 1e-12)
}

/// Hangover state machine: consecutive voiced frames start speech, a continuous
/// silence run ends it. Fires `endpoint` once, then stays inert until `reset`.
/// Never fires before speech started. Port of `EndpointDetector`.
final class EndpointDetector {
    private let speechFrames: Int
    private let silenceFrames: Int
    private let gate: Double

    private var started = false
    private var fired = false
    private var voicedRun = 0
    private var silentRun = 0

    init(silenceMs: Int, minSpeechMs: Int, frameMs: Int, energyGateDbfs: Double) {
        self.speechFrames = max(1, Int(ceil(Double(minSpeechMs) / Double(frameMs))))
        self.silenceFrames = max(1, Int(ceil(Double(silenceMs) / Double(frameMs))))
        self.gate = energyGateDbfs
        reset()
    }

    func reset() {
        started = false
        fired = false
        voicedRun = 0
        silentRun = 0
    }

    /// 0..1 progress toward auto-stop (the HUD's countdown affordance).
    var silenceFraction: Double {
        if !started { return 0.0 }
        return min(1.0, Double(silentRun) / Double(silenceFrames))
    }

    func feed(voiced: Bool, energyDbfs: Double) -> VadEvent? {
        if fired { return nil }
        let effective = voiced && energyDbfs >= gate
        if !started {
            voicedRun = effective ? voicedRun + 1 : 0
            if voicedRun >= speechFrames {
                started = true
                silentRun = 0
                return .speechStart
            }
            return nil
        }
        if effective {
            silentRun = 0
            return nil
        }
        silentRun += 1
        if silentRun >= silenceFrames {
            fired = true
            return .endpoint
        }
        return nil
    }
}

/// Speech classifier seam. Port of `VadBackend`.
protocol VadBackend {
    var frameSamples: Int { get }
    func isVoiced(_ frame: [Int16]) -> Bool
}

/// M5's energy-only backend: always votes voiced so the detector's energy gate
/// is the sole classifier. 30 ms frames at 16 kHz.
struct EnergyGateBackend: VadBackend {
    let frameSamples = 480
    func isVoiced(_ frame: [Int16]) -> Bool { true }
}

/// One armed hands-free session: frames in, at most one endpoint out.
/// `arm(generation:)` stamps the session id the controller checks before acting
/// on an endpoint (a stale event queued across sessions must never stop the next
/// one). Auto-disarms after firing. Port of `Endpointer`.
final class Endpointer {
    let backend: VadBackend
    private let detector: EndpointDetector
    private let slicer: FrameSlicer
    private let capSamples: Int
    private let warnSamples: Int

    private(set) var armed = false
    private(set) var generation = 0
    private var samples = 0
    private var capWarned = false

    init(backend: VadBackend, detector: EndpointDetector, maxSessionS: Double,
         sampleRate: Int = vadSampleRate) {
        self.backend = backend
        self.detector = detector
        self.slicer = FrameSlicer(frameSamples: backend.frameSamples)
        self.capSamples = Int(maxSessionS * Double(sampleRate))
        self.warnSamples = Int(Double(capSamples) * capWarnFraction)
    }

    func arm(generation: Int) {
        self.generation = generation
        detector.reset()
        slicer.reset()
        samples = 0
        capWarned = false
        armed = true
    }

    func disarm() { armed = false }

    /// Audio-callback thread. Returns `(event, silenceFraction)`.
    func process(_ block: [Float]) -> (VadEvent?, Double?) {
        guard armed else { return (nil, nil) }
        samples += block.count
        var event: VadEvent? = nil
        for frame in slicer.add(block) {
            if let e = detector.feed(voiced: backend.isVoiced(frame), energyDbfs: frameDbfs(frame)) {
                event = e
            }
        }
        if event != .endpoint && samples >= capSamples {
            event = .endpoint
        } else if event == nil && !capWarned && samples >= warnSamples {
            capWarned = true
            event = .capWarning
        }
        if event == .endpoint { armed = false }
        return (event, detector.silenceFraction)
    }
}
