import XCTest
@testable import Pomvox

/// The post-show self-probe: given CGWindowList-shaped rows, is a pill-sized
/// window of ours actually on screen? Pure decision so it runs without a
/// window server (CI).
final class HudProbeTests: XCTestCase {
    private let pill = HudConst.pillSize  // 420×64

    private func win(pid: Int = 42, w: CGFloat = 420, h: CGFloat = 64,
                     alpha: Double = 1.0, layer: Int = 25) -> HudWindowInfo {
        HudWindowInfo(ownerPID: pid, size: CGSize(width: w, height: h),
                      alpha: alpha, layer: layer)
    }

    func testFindsThePill() {
        XCTAssertTrue(hudPillFound(windows: [win()], pid: 42, pillSize: pill))
    }

    func testIgnoresOtherProcessesWindows() {
        XCTAssertFalse(hudPillFound(windows: [win(pid: 7)], pid: 42, pillSize: pill))
    }

    func testIgnoresWrongSizedWindows() {
        // The Hub window, menus, etc. — only the 420×64 pill counts.
        XCTAssertFalse(hudPillFound(windows: [win(w: 900, h: 600)], pid: 42, pillSize: pill))
    }

    func testToleratesSubpixelRounding() {
        XCTAssertTrue(hudPillFound(windows: [win(w: 421, h: 63.5)], pid: 42, pillSize: pill))
    }

    func testFullyTransparentPillDoesNotCount() {
        // alpha 0 = the fade-out completed / show never applied alpha 1.
        XCTAssertFalse(hudPillFound(windows: [win(alpha: 0.0)], pid: 42, pillSize: pill))
    }

    func testEmptyWindowListDoesNotCount() {
        XCTAssertFalse(hudPillFound(windows: [], pid: 42, pillSize: pill))
    }

    // MARK: - probe policy (self-heal on miss, at most once per show)

    func testVisiblePillNeedsNoAction() {
        XCTAssertEqual(hudProbeAction(pillVisible: true, isPostHealCheck: false), .none)
    }

    func testMissTriggersHeal() {
        // The 2026-07-11 wedge: orderFrontRegardless no-ops on the old window.
        // A fresh panel is the proven fix — rebuild and verify.
        XCTAssertEqual(hudProbeAction(pillVisible: false, isPostHealCheck: false),
                       .healAndRecheck)
    }

    func testHealedPillNeedsNoAction() {
        XCTAssertEqual(hudProbeAction(pillVisible: true, isPostHealCheck: true), .none)
    }

    func testMissAfterHealOnlyReports() {
        // Never heal twice for one show(): if a FRESH panel also can't order
        // in (locked screen, exotic breakage), report and stop — no loop.
        XCTAssertEqual(hudProbeAction(pillVisible: false, isPostHealCheck: true),
                       .reportHealFailed)
    }

    func testMissOnLockedScreenSkipsHeal() {
        // A locked screen can't display the pill — healing would waste a
        // rebuild and mislabel the environment as the window-server wedge.
        XCTAssertEqual(hudProbeAction(pillVisible: false, isPostHealCheck: false,
                                      screenLocked: true),
                       .skipLockedScreen)
    }

    func testMissAfterHealOnLockedScreenAlsoSkips() {
        XCTAssertEqual(hudProbeAction(pillVisible: false, isPostHealCheck: true,
                                      screenLocked: true),
                       .skipLockedScreen)
    }

    func testVisiblePillOnLockedScreenNeedsNoAction() {
        // Visibility wins — if the pill somehow displays, nothing to do.
        XCTAssertEqual(hudProbeAction(pillVisible: true, isPostHealCheck: false,
                                      screenLocked: true),
                       .none)
    }
}
