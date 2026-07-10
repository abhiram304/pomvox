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
}
