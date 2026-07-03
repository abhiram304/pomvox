import XCTest
@testable import Pomvox

/// The coalesce-once + latest-wins contract of the HUD bus (port of the Python
/// `uibus` Coalescer behavior). Uses a manual scheduler so we can assert exactly
/// one wake-up per burst.
final class HudBusTests: XCTestCase {

    func testCoalescerReportsWakeupOnlyOnFirstDirtyPost() {
        let c = HudCoalescer()
        XCTAssertTrue(c.post(.level(0.1)))    // first post → schedule a wake-up
        XCTAssertFalse(c.post(.level(0.2)))   // still dirty → ride the pending one
        XCTAssertFalse(c.post(.draft("hi")))
        _ = c.drain()
        XCTAssertTrue(c.post(.level(0.3)))    // drained → next post schedules again
    }

    func testCoalescerKeepsLatestPerChannel() {
        let c = HudCoalescer()
        _ = c.post(.level(0.1))
        _ = c.post(.level(0.9))               // latest wins
        _ = c.post(.draft("a"))
        _ = c.post(.draft("b"))
        let drained = c.drain()
        XCTAssertEqual(drained.count, 2)
        if case let .level(v)? = drained[.level] { XCTAssertEqual(v, 0.9) } else { XCTFail("no level") }
        if case let .draft(t)? = drained[.draft] { XCTAssertEqual(t, "b") } else { XCTFail("no draft") }
        XCTAssertTrue(c.drain().isEmpty)       // drain clears
    }

    func testBusSchedulesOneDrainForABurst() {
        var scheduled: [() -> Void] = []
        var rendered: [[UiEvent: HudPayload]] = []
        let bus = HudBus(render: { rendered.append($0) },
                         schedule: { scheduled.append($0) })

        bus.post(.level(0.1))
        bus.post(.level(0.5))
        bus.post(.draft("draft"))
        XCTAssertEqual(scheduled.count, 1, "a burst costs exactly one wake-up")

        scheduled.forEach { $0() }   // run the drain on the "main thread"
        XCTAssertEqual(rendered.count, 1)
        if case let .level(v)? = rendered[0][.level] { XCTAssertEqual(v, 0.5) } else { XCTFail("no level") }

        bus.post(.level(0.7))        // after the drain, a fresh wake-up
        XCTAssertEqual(scheduled.count, 2)
    }
}
