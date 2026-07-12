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
}
