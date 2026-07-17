import Foundation

/// Idle-eviction policy for the cleanup LLM (item 5). The ~2.3 GB Qwen model is
/// used in bursts, so it shouldn't sit resident 24/7: after it goes unused for
/// `idleEvictS`, unload it and reload on next use. The small (~600 MB) STT model
/// stays resident — this policy is cleanup-only.
///
/// Pure decision logic (last-use + now → evict?) so the timer wiring in
/// `NativeEngine` stays a thin shell and the boundary is unit-tested.
enum CleanupResidency {
    /// The default idle window before the cleanup model is evicted (seconds).
    static let defaultIdleEvictS: Double = 300

    /// The default delay after arm before the cleanup model is preloaded in the
    /// background (seconds) — long enough not to block startup, short enough
    /// that a user reading the UI has a warm model before their first dictation.
    static let defaultPreloadDelayS: Double = 20

    /// Whether the cleanup model should be evicted now.
    ///
    /// - Only when it's actually `loaded` (nothing to evict otherwise).
    /// - `idleEvictS <= 0` disables eviction (keep resident).
    /// - A `nil` `lastUsedAt` (loaded but never used, e.g. a background preload)
    ///   still counts toward eviction from `loadedAt` if provided, else never.
    static func shouldEvict(
        loaded: Bool, lastUsedAt: Double?, loadedAt: Double?, now: Double, idleEvictS: Double
    ) -> Bool {
        guard loaded, idleEvictS > 0 else { return false }
        // Idle is measured from the most recent of "last used" and "loaded"
        // (a freshly preloaded-but-unused model isn't instantly stale).
        let reference = [lastUsedAt, loadedAt].compactMap { $0 }.max()
        guard let reference else { return false }
        return (now - reference) >= idleEvictS
    }

    /// How often the residency watchdog should wake to check for idleness —
    /// frequent enough to be timely, coarse enough to cost nothing at rest.
    static func checkIntervalS(idleEvictS: Double) -> Double {
        max(5.0, min(60.0, idleEvictS / 5.0))
    }

    /// How long `clean()` waits for a reload to *begin* when none is marked
    /// in-flight yet: the key-up fires the reload as a detached task, so the
    /// utterance's cleanup can reach the engine actor before `prepare()` does.
    /// Short, so a genuinely failed/absent load still falls back fast.
    static let loadStartGraceS: Double = 0.25

    /// Whether a per-utterance `clean()` should keep waiting for an in-flight
    /// background reload instead of giving up and pasting raw.
    ///
    /// The post-eviction dictation races the fire-and-forget reload that its
    /// own key-up triggered (`ensureCleanupLoaded`): bailing the moment the
    /// container is nil pasted raw after every idle gap longer than
    /// `idleEvictS` (on-device history 2026-07-16: 16 of 60 dictations).
    /// Waiting is bounded by the utterance's own cleanup deadline, so the
    /// never-lose-words fallback is unchanged — just not taken prematurely.
    /// `entered` is when this clean() started: within `loadStartGraceS` of it,
    /// wait even if no load is marked in-flight yet (see above).
    static func shouldAwaitLoad(
        loaded: Bool, loading: Bool, now: Double, deadline: Double, entered: Double
    ) -> Bool {
        guard !loaded, now < deadline else { return false }
        return loading || now < entered + loadStartGraceS
    }
}

/// Identity of the prompt-prefix KV caches: valid for exactly one (model,
/// dictionary-hint) pair. The caches are pure K/V tensors (~100 MB) derived
/// from the prompt bytes, so they survive idle eviction of the ~2.3 GB
/// weights and stay valid across a reload of the SAME model — a mismatch on
/// either field means the next `prepare()` must re-prefill.
struct PrefixCacheKey: Equatable {
    let modelID: String
    let hint: String
}
