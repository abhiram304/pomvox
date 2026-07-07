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
}
