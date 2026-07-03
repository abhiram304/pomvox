import XCTest
@testable import Pomvox

/// 1:1 port of `tests/test_hotkey_machine.py` — table/test-vector parity with
/// the Linux-tested Python spec, not re-derived.
final class HotkeyMachineTests: XCTestCase {
    let FN = HotkeyMachine.keycodes["fn"]!
    let SPACE = HotkeyMachine.keycodes["space"]!
    let ESC = HotkeyMachine.keycodes["esc"]!
    let RIGHT_OPT = HotkeyMachine.keycodes["right_option"]!
    let LETTER_A = 0  // any non-hotkey keycode

    private func make() -> HotkeyMachine { try! HotkeyMachine() }

    func testPttPressAndRelease() {
        let m = make()
        var d = m.onModifier(FN, true)
        XCTAssertEqual(d.action, .startPTT); XCTAssertFalse(d.swallow)
        XCTAssertEqual(m.state, .ptt)

        d = m.onModifier(FN, false)
        XCTAssertEqual(d.action, .stop); XCTAssertFalse(d.swallow)
        XCTAssertEqual(m.state, .busy)

        m.done()
        XCTAssertEqual(m.state, .idle)
    }

    func testFnSpaceEntersToggleAndSwallows() {
        let m = make()
        _ = m.onModifier(FN, true)
        var d = m.onKeyDown(SPACE)
        XCTAssertEqual(d.action, .enterToggle); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .toggle)

        // Releasing Fn no longer stops the recording.
        d = m.onModifier(FN, false)
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(m.state, .toggle)
    }

    func testEscCancelsToggleAndSwallows() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        let d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .cancel); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .busy)
    }

    func testEscCancelsPttAndSwallows() {
        let m = make()
        _ = m.onModifier(FN, true)
        var d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .cancel); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .busy)

        // The trailing Fn release must not emit a second STOP.
        d = m.onModifier(FN, false)
        XCTAssertEqual(d.action, .none)
    }

    func testConfiguredStopKeyStillStopsToggle() {
        let m = try! HotkeyMachine(stop: "right_command")
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        let d = m.onKeyDown(HotkeyMachine.keycodes["right_command"]!)
        XCTAssertEqual(d.action, .stop); XCTAssertTrue(d.swallow)
    }

    func testCancelDisabledWhenUnset() {
        let m = try! HotkeyMachine(cancel: "")
        _ = m.onModifier(FN, true)
        let d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testEscWhileBusyPassesThrough() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onModifier(FN, false)  // STOP → BUSY; a late Esc is too late to cancel
        let d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testFnTapStopsToggle() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        let d = m.onModifier(FN, true)
        XCTAssertEqual(d.action, .stop)
        XCTAssertEqual(m.state, .busy)
    }

    func testSecondFnSpaceStopsToggleWithoutTypingASpace() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        // Fn going down already stops; the trailing space must be swallowed so
        // it isn't typed into the document.
        var d = m.onModifier(FN, true)
        XCTAssertEqual(d.action, .stop)
        d = m.onKeyDown(SPACE)
        XCTAssertEqual(d.action, .none); XCTAssertTrue(d.swallow)
    }

    func testUnrelatedKeysPassThrough() {
        let m = make()
        XCTAssertEqual(m.onKeyDown(LETTER_A).action, .none)

        _ = m.onModifier(FN, true)
        var d = m.onKeyDown(LETTER_A)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)

        _ = m.onKeyDown(SPACE)  // toggle mode
        d = m.onKeyDown(LETTER_A)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testSpaceWithoutFnPassesInToggleEntry() {
        let m = make()
        // Space in IDLE is never a hotkey.
        let d = m.onKeyDown(SPACE)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testEventsWhileBusyAreIgnored() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onModifier(FN, false)  // → BUSY (transcribing)

        XCTAssertEqual(m.onModifier(FN, true).action, .none)
        XCTAssertEqual(m.onKeyDown(SPACE).action, .none)
        XCTAssertEqual(m.onKeyDown(ESC).action, .none)
        XCTAssertEqual(m.state, .busy)

        m.done()
        XCTAssertEqual(m.onModifier(FN, true).action, .startPTT)
    }

    func testRemappedPttKey() {
        let m = try! HotkeyMachine(ptt: "right_option")
        XCTAssertEqual(m.onModifier(FN, true).action, .none)
        XCTAssertEqual(m.onModifier(RIGHT_OPT, true).action, .startPTT)
        XCTAssertEqual(m.onModifier(RIGHT_OPT, false).action, .stop)
    }

    func testInvalidKeyNamesRaise() {
        XCTAssertThrowsError(try HotkeyMachine(ptt: "hyperkey"))
        XCTAssertThrowsError(try HotkeyMachine(toggle: "space"))  // missing modifier
    }

    func testResetAbortsRecording() {
        let m = make()
        _ = m.onModifier(FN, true)
        m.reset()
        XCTAssertEqual(m.state, .idle)
    }

    func testExternalStopOnlyFiresInToggle() {
        let m = make()
        // VAD endpoint while hands-free: stops exactly like the stop hotkey.
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)
        XCTAssertTrue(m.externalStop())
        XCTAssertEqual(m.state, .busy)

        // And never anywhere else: BUSY (a second stale endpoint), PTT
        // (the finger is the endpoint), IDLE.
        XCTAssertFalse(m.externalStop())
        m.done()
        XCTAssertFalse(m.externalStop())
        _ = m.onModifier(FN, true)  // PTT
        XCTAssertFalse(m.externalStop())
        XCTAssertEqual(m.state, .ptt)
    }
}
