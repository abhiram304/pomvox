import XCTest
@testable import Pomvox

/// Idle-eviction policy for the cleanup LLM (item 5): the pure decision that the
/// engine's timer wiring drives. STT residency is unaffected — this is
/// cleanup-only.
final class CleanupResidencyTests: XCTestCase {

    func testNotLoadedNeverEvicts() {
        XCTAssertFalse(CleanupResidency.shouldEvict(
            loaded: false, lastUsedAt: 0, loadedAt: 0, now: 10_000, idleEvictS: 300))
    }

    func testEvictsOnlyAfterTheIdleWindow() {
        // Used at t=0, window 300s. At t=299 keep; at t=300 evict.
        XCTAssertFalse(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: 0, loadedAt: nil, now: 299, idleEvictS: 300))
        XCTAssertTrue(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: 0, loadedAt: nil, now: 300, idleEvictS: 300))
    }

    func testIdleMeasuredFromMostRecentOfUseOrLoad() {
        // Loaded at 100, never used: idle counts from load, not from 0.
        XCTAssertFalse(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: nil, loadedAt: 100, now: 399, idleEvictS: 300))
        XCTAssertTrue(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: nil, loadedAt: 100, now: 400, idleEvictS: 300))
        // A later use resets the clock past the load time.
        XCTAssertFalse(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: 500, loadedAt: 100, now: 700, idleEvictS: 300))
    }

    func testNonPositiveWindowDisablesEviction() {
        XCTAssertFalse(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: 0, loadedAt: 0, now: 1_000_000, idleEvictS: 0))
    }

    func testLoadedButNoTimestampsDoesNotEvict() {
        XCTAssertFalse(CleanupResidency.shouldEvict(
            loaded: true, lastUsedAt: nil, loadedAt: nil, now: 10_000, idleEvictS: 300))
    }

    func testCheckIntervalIsClampedAndProportional() {
        XCTAssertEqual(CleanupResidency.checkIntervalS(idleEvictS: 300), 60)   // 300/5, clamped to 60
        XCTAssertEqual(CleanupResidency.checkIntervalS(idleEvictS: 30), 6)     // 30/5
        XCTAssertEqual(CleanupResidency.checkIntervalS(idleEvictS: 10), 5)     // floor at 5
    }

    // MARK: - post-eviction reload wait (clean() must not paste raw mid-reload)

    func testAwaitsAnInFlightLoadUntilTheDeadline() {
        XCTAssertTrue(CleanupResidency.shouldAwaitLoad(
            loaded: false, loading: true, now: 0, deadline: 12.5, entered: 0))
        XCTAssertFalse(CleanupResidency.shouldAwaitLoad(
            loaded: false, loading: true, now: 12.5, deadline: 12.5, entered: 0))
    }

    func testDoesNotAwaitWhenLoadedOrNotLoading() {
        // Loaded: generate now. Not loading (and past the start grace):
        // nothing to wait for — the load failed or never started, so give up
        // immediately as before.
        XCTAssertFalse(CleanupResidency.shouldAwaitLoad(
            loaded: true, loading: true, now: 0, deadline: 12.5, entered: 0))
        XCTAssertFalse(CleanupResidency.shouldAwaitLoad(
            loaded: false, loading: false, now: 1.0, deadline: 12.5, entered: 0))
    }

    func testGraceWindowCoversALoadAboutToStart() {
        // The dictation's own key-up fires the reload as a detached task, so
        // clean() can reach the actor before prepare() flips `loading`. Within
        // the short start grace, wait for it; past the grace, give up.
        XCTAssertTrue(CleanupResidency.shouldAwaitLoad(
            loaded: false, loading: false, now: 0.1, deadline: 12.5, entered: 0))
        XCTAssertFalse(CleanupResidency.shouldAwaitLoad(
            loaded: false, loading: false,
            now: CleanupResidency.loadStartGraceS + 0.01, deadline: 12.5, entered: 0))
        // The grace never outlives the utterance deadline.
        XCTAssertFalse(CleanupResidency.shouldAwaitLoad(
            loaded: false, loading: false, now: 0.1, deadline: 0.05, entered: 0))
    }

    // MARK: - prefix-cache retention across eviction

    func testPrefixCachesSurviveSameModelAndHint() {
        let key = PrefixCacheKey(modelID: "mlx-community/Qwen3-4B-4bit", hint: "")
        XCTAssertEqual(key, PrefixCacheKey(modelID: "mlx-community/Qwen3-4B-4bit", hint: ""))
    }

    func testPrefixCachesRebuiltOnModelOrHintChange() {
        let key = PrefixCacheKey(modelID: "mlx-community/Qwen3-4B-4bit", hint: "")
        XCTAssertNotEqual(key, PrefixCacheKey(modelID: "mlx-community/Qwen3-1.7B-4bit", hint: ""))
        XCTAssertNotEqual(
            key,
            PrefixCacheKey(
                modelID: "mlx-community/Qwen3-4B-4bit",
                hint: "- Keep these terms spelled exactly: Salammagari.\n"))
    }
}
