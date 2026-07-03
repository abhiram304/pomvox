import Foundation

/// Port of `src/pomvox/bench.py` `Timings` — stamps named stages for one
/// utterance, relative to recording stop. `stagesMs()` yields each stage as the
/// delta to the previous stamp plus a "total", exactly the dict Python dumps
/// into `history.timings_json` (keys: stt_finalize, cleanup, insert, total).
struct EngineTimings {
    private let clock: () -> Double
    private var t0: Double?
    private var stamps: [(name: String, t: Double)] = []

    init(clock: @escaping () -> Double = { CFAbsoluteTimeGetCurrent() }) {
        self.clock = clock
    }

    /// Mark t0 = recording stop.
    mutating func start() {
        t0 = clock()
        stamps = []
    }

    /// Mark t0 explicitly (the engine already holds `stopAt` from the tap thread).
    mutating func start(at t: Double) {
        t0 = t
        stamps = []
    }

    mutating func stamp(_ name: String) {
        stamps.append((name, clock()))
    }

    /// Stamp at an explicit time (the paste moment is measured on the main
    /// actor; the stamp lands after the hop back).
    mutating func stamp(_ name: String, at t: Double) {
        stamps.append((name, t))
    }

    /// Per-stage durations (each relative to the previous stamp) + total, in ms.
    func stagesMs() -> [(name: String, ms: Double)] {
        guard let t0 else { return [] }
        var out: [(name: String, ms: Double)] = []
        var prev = t0
        for (name, t) in stamps {
            out.append((name, (t - prev) * 1000.0))
            prev = t
        }
        if let last = stamps.last {
            out.append(("total", (last.t - t0) * 1000.0))
        }
        return out
    }

    /// The `timings_json` payload — same shape as Python's
    /// `json.dumps(timings.stages_ms())`. "{}" when nothing was stamped.
    func json() -> String {
        let stages = stagesMs()
        guard !stages.isEmpty else { return "{}" }
        let body = stages
            .map { "\"\($0.name)\": \($0.ms)" }
            .joined(separator: ", ")
        return "{\(body)}"
    }

    /// `summary()` analog for the engine log line.
    func summary() -> String {
        stagesMs().map { String(format: "%@=%.0fms", $0.name, $0.ms) }.joined(separator: " ")
    }
}
