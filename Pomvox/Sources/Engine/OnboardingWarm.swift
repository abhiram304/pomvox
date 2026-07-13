import Foundation

/// One-time "warm both models during onboarding" gate (item 2).
///
/// The first dictation feels slow because the cold-start cost (model download,
/// CoreML compile, ANE warmup, cleanup-LLM load) lands on it. On a fresh install
/// we instead pay that cost the first time the engine arms — while the user is
/// still in Setup — by warming the cleanup model eagerly then, rather than
/// deferring it like the steady-state lazy path (see `CleanupResidency`). After
/// that first warm, later launches stay lazy.
///
/// State is a single UserDefaults flag (native-app state, not shared config).
/// Injectable defaults keep the decision unit-testable.
struct OnboardingWarm {
    static let warmedKey = "onboarding.modelsWarmed"

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// True until the first-run warm has happened — the caller should warm both
    /// models now instead of deferring the cleanup load.
    var shouldWarmNow: Bool { !defaults.bool(forKey: Self.warmedKey) }

    /// Record that the first-run warm has been kicked off, so later launches use
    /// the lazy path. Marked once the warm is initiated (not gated on success):
    /// a failed warm shouldn't force every future launch down the eager path.
    func markWarmed() { defaults.set(true, forKey: Self.warmedKey) }
}
