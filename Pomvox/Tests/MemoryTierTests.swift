import XCTest
@testable import Pomvox

/// Memory-aware first-run defaults: the low-memory tier boundary and the
/// cleanup-default decision, which must never override an existing config.
final class MemoryTierTests: XCTestCase {
    private static let gb: UInt64 = 1024 * 1024 * 1024

    func testEightGBIsLowMemory() {
        XCTAssertTrue(MemoryTier.isLowMemory(8 * Self.gb))
    }

    func testSixteenGBIsNotLowMemory() {
        XCTAssertFalse(MemoryTier.isLowMemory(16 * Self.gb))
    }

    func testBoundaryAllowsSlightlyUnderEightGB() {
        // Some 8 GB machines report marginally under 8 × 1024³.
        XCTAssertTrue(MemoryTier.isLowMemory(8 * Self.gb - 100 * 1024 * 1024))
        XCTAssertTrue(MemoryTier.isLowMemory(MemoryTier.lowMemoryMaxBytes))
        XCTAssertFalse(MemoryTier.isLowMemory(MemoryTier.lowMemoryMaxBytes + 1))
    }

    func testExistingConfigAlwaysDefaultsCleanupOn() {
        // Non-breaking guarantee: a machine that has run Pomvox before is never
        // flipped off, even on low RAM.
        XCTAssertTrue(MemoryTier.firstRunCleanupDefault(
            configExists: true, physicalMemoryBytes: 8 * Self.gb))
        XCTAssertTrue(MemoryTier.firstRunCleanupDefault(
            configExists: true, physicalMemoryBytes: 16 * Self.gb))
    }

    func testFreshInstallOnLowMemoryDefaultsCleanupOff() {
        XCTAssertFalse(MemoryTier.firstRunCleanupDefault(
            configExists: false, physicalMemoryBytes: 8 * Self.gb))
    }

    func testFreshInstallOnAmpleMemoryDefaultsCleanupOn() {
        XCTAssertTrue(MemoryTier.firstRunCleanupDefault(
            configExists: false, physicalMemoryBytes: 16 * Self.gb))
    }
}
