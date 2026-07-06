import Foundation

/// Live, human-readable status for the one-time model downloads. The first-run
/// speech-model fetch is ~460 MB and blocks the engine for a while; without a
/// visible percentage the menu bar just reads "Preparing…" and the first
/// dictation looks like a hang. These are the pure pieces the engine drives:
/// `line(_:)` formats one status string, `LineGate` collapses the flood of
/// progress callbacks down to the distinct lines actually worth rendering.
enum ModelLoad {
    /// Which model is loading. The speech model gates dictation (its line stands
    /// in for the engine status while preparing); the polish/cleanup model loads
    /// in the background after the engine is already usable (a secondary note).
    enum Model {
        case speech, polish
        var noun: String { self == .speech ? "speech" : "polish" }
    }

    /// One status line. `fraction` is [0, 1] while a network download is in
    /// flight; pass `downloading: false` (or a nil fraction) once the bytes are
    /// down and the model is compiling / loading into memory — an indeterminate
    /// phase with no meaningful percentage.
    static func line(_ model: Model, fraction: Double?, downloading: Bool) -> String {
        if downloading, let fraction {
            let pct = max(0, min(100, Int((fraction * 100).rounded())))
            return "Downloading the \(model.noun) model… \(pct)%"
        }
        return "Loading the \(model.noun) model…"
    }
}

/// Collapses a stream of progress callbacks — which may arrive on any queue and
/// far faster than a UI needs — to only the moments the rendered line actually
/// changes (integer-percent steps and phase transitions). Thread-safe so the
/// engine can gate *before* hopping to the main actor, keeping @Published churn
/// to ~100 updates across a multi-hundred-MB download.
final class LineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?

    /// True the first time `line` differs from the previously admitted one.
    func changed(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard line != last else { return false }
        last = line
        return true
    }
}
