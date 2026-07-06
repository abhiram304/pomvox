import XCTest
@testable import Pomvox

/// First-run discoverability decisions — the pure logic behind landing a fresh
/// user on Setup and flagging it in the menu bar / sidebar.
final class FirstRunRoutingTests: XCTestCase {

    func testFreshUserLandsOnSetup() {
        XCTAssertEqual(NavItem.firstRun(allPermissionsGranted: false), .setup)
    }

    func testGrantedUserLandsOnHome() {
        XCTAssertEqual(NavItem.firstRun(allPermissionsGranted: true), .home)
    }

    func testSetupNudgeWhenAnyGrantMissing() {
        XCTAssertTrue(SetupNudge.needed(engineNeedsAttention: false, allPermissionsGranted: false))
    }

    func testSetupNudgeWhenEngineNeedsAttentionEvenIfGranted() {
        // e.g. Input Monitoring granted but the tap died after sleep.
        XCTAssertTrue(SetupNudge.needed(engineNeedsAttention: true, allPermissionsGranted: true))
    }

    func testNoNudgeOnceSetUpAndHealthy() {
        XCTAssertFalse(SetupNudge.needed(engineNeedsAttention: false, allPermissionsGranted: true))
    }
}
