import XCTest
@testable import Pomvox

/// 1:1 port of `tests/test_hud.py` — test-vector parity with the Linux-tested
/// Python spec (split_stable_prefix, LevelHistory, geometry, level mapping, and
/// the HudStateMachine), not re-derived.
final class HudLogicTests: XCTestCase {

    // MARK: - split_stable_prefix

    func testSplitStablePrefixMarksTheNewChunk() {
        let (stable, delta) = splitStablePrefix("the quick", "the quick brown fox")
        XCTAssertEqual(stable, "the quick")
        XCTAssertEqual(delta, " brown fox")
    }

    func testSplitStablePrefixHandlesRevisions() {
        // Parakeet may revise earlier words between chunks: the changed part
        // counts as new.
        let (stable, delta) = splitStablePrefix("the quik brown", "the quick brown fox")
        XCTAssertEqual(stable, "the qui")
        XCTAssertEqual(delta, "ck brown fox")
    }

    func testSplitStablePrefixFirstDraftIsAllNew() {
        let (stable, delta) = splitStablePrefix("", "hello")
        XCTAssertEqual(stable, "")
        XCTAssertEqual(delta, "hello")
    }

    // MARK: - LevelHistory

    func testLevelHistoryKeepsAFixedWindowNewestLast() {
        let h = LevelHistory(n: 3)
        for v in [0.1, 0.2, 0.3, 0.4] { h.push(v) }
        XCTAssertEqual(h.bars(), [0.2, 0.3, 0.4])
    }

    func testLevelHistoryPadsWithZerosUntilFull() {
        let h = LevelHistory(n: 4)
        h.push(0.5)
        XCTAssertEqual(h.bars(), [0.0, 0.0, 0.0, 0.5])
    }

    func testLevelHistoryResetFlattens() {
        let h = LevelHistory(n: 2)
        h.push(0.9)
        h.reset()
        XCTAssertEqual(h.bars(), [0.0, 0.0])
    }

    // MARK: - pill_frame

    func testPillFrameNotchHugsTheTopEdge() {
        let f = pillFrame(visibleFrame: (0.0, 0.0, 1000.0, 600.0),
                          pillSize: CGSize(width: 420.0, height: 64.0), margin: 24.0,
                          position: "notch")
        XCTAssertEqual(f.y, 600.0 - 64.0)   // no margin
        XCTAssertEqual(f.x, 290.0)
    }

    func testPillFrameCentersAtBottom() {
        let f = pillFrame(visibleFrame: (0.0, 0.0, 1000.0, 600.0),
                          pillSize: CGSize(width: 420.0, height: 64.0), margin: 24.0)
        XCTAssertEqual(f.x, 290.0)
        XCTAssertEqual(f.y, 24.0)
        XCTAssertEqual(f.w, 420.0)
        XCTAssertEqual(f.h, 64.0)
    }

    func testPillFrameHandlesNegativeOriginScreens() {
        let f = pillFrame(visibleFrame: (-1920.0, -200.0, 1920.0, 1080.0),
                          pillSize: CGSize(width: 420.0, height: 64.0), margin: 24.0)
        XCTAssertEqual(f.x, -1920.0 + (1920.0 - 420.0) / 2)
        XCTAssertEqual(f.y, -176.0)
    }

    func testPillFrameTopCenter() {
        let f = pillFrame(visibleFrame: (0.0, 0.0, 1000.0, 600.0),
                          pillSize: CGSize(width: 420.0, height: 64.0), margin: 24.0,
                          position: "top-center")
        XCTAssertEqual(f.y, 600.0 - 64.0 - 24.0)
    }

    // MARK: - truncate_head

    func testTruncateHeadKeepsTheNewestWords() {
        XCTAssertEqual(truncateHead("the quick brown fox", 10), "…brown fox")
    }

    func testTruncateHeadShortTextUntouched() {
        XCTAssertEqual(truncateHead("hi there", 20), "hi there")
    }

    // MARK: - level01

    func testLevel01MapsSpeechRange() {
        XCTAssertEqual(level01(-60.0), 0.0)    // silence floor
        XCTAssertEqual(level01(-10.0), 1.0)    // loud speech ceiling
        XCTAssertTrue(0.0 < level01(-35.0) && level01(-35.0) < 1.0)
    }

    func testLevel01ClampsOutOfRange() {
        XCTAssertEqual(level01(-120.0), 0.0)
        XCTAssertEqual(level01(0.0), 1.0)
    }

    // MARK: - HudStateMachine

    private func make() -> HudStateMachine { HudStateMachine(maxChars: 40) }

    func testStartsHidden() {
        XCTAssertFalse(make().vm.visible)
    }

    func testRecordingShowsWithStatus() {
        let m = make()
        let vm = m.apply([.state: .state("recording", "recording (push-to-talk)")], now: 0.0)
        XCTAssertTrue(vm.visible)
        XCTAssertEqual(vm.state, "recording")
        XCTAssertTrue(vm.status.contains("push-to-talk"))
    }

    func testDraftAndLevelUpdateWhileRecording() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.draft: .draft("hello world"), .level: .level(0.7)], now: 1.0)
        XCTAssertEqual(vm.draft, "hello world")
        XCTAssertEqual(vm.level, 0.7)
    }

    func testDraftIsHeadTruncated() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.draft: .draft(String(repeating: "x", count: 100))], now: 1.0)
        XCTAssertEqual(vm.draft.count, 40)
        XCTAssertTrue(vm.draft.hasPrefix("…"))
    }

    func testDraftIgnoredWhenHidden() {
        let m = make()
        let vm = m.apply([.draft: .draft("stray")], now: 0.0)
        XCTAssertFalse(vm.visible)
        XCTAssertEqual(vm.draft, "")
    }

    func testTranscribingFreezesDraft() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        _ = m.apply([.draft: .draft("so far")], now: 1.0)
        let vm = m.apply([.state: .state("transcribing", "")], now: 2.0)
        XCTAssertEqual(vm.state, "transcribing")
        XCTAssertEqual(vm.draft, "so far")
    }

    func testOkResultFlashesThenHidesOnTick() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        _ = m.apply([.state: .state("transcribing", "")], now: 2.0)
        let vm = m.apply([.result: .result("ok", "Final text.")], now: 3.0)
        XCTAssertEqual(vm.state, "done")
        XCTAssertEqual(vm.final, "Final text.")
        XCTAssertNotNil(vm.hideAt)
        XCTAssertGreaterThan(vm.hideAt!, 3.0)
        XCTAssertTrue(m.tick(now: vm.hideAt! - 0.1).visible)
        XCTAssertFalse(m.tick(now: vm.hideAt!).visible)
    }

    func testResultBeatsIdleInTheSameDrain() {
        // _on_text posts RESULT then STATE idle; one drain may carry both.
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.result: .result("ok", "kept"), .state: .state("idle", "ready")], now: 1.0)
        XCTAssertEqual(vm.state, "done")
        XCTAssertEqual(vm.final, "kept")
    }

    func testIdleWhileDoneDoesNotCutTheFlashShort() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        _ = m.apply([.result: .result("ok", "kept")], now: 1.0)
        let vm = m.apply([.state: .state("idle", "ready")], now: 1.1)
        XCTAssertEqual(vm.state, "done")
    }

    func testErrorResultShowsWarning() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.result: .result("error", "copied to clipboard")], now: 1.0)
        XCTAssertEqual(vm.state, "error")
        XCTAssertTrue(vm.status.contains("copied to clipboard"))
        XCTAssertNotNil(vm.hideAt)
    }

    func testEmptyResultHidesImmediately() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.result: .result("empty", "")], now: 1.0)
        XCTAssertFalse(vm.visible)
    }

    func testRerecordDuringDoneFlashCancelsTheHide() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        _ = m.apply([.result: .result("ok", "first")], now: 1.0)
        let vm = m.apply([.state: .state("recording", "")], now: 1.2)
        XCTAssertEqual(vm.state, "recording")
        XCTAssertNil(vm.hideAt)
        XCTAssertEqual(vm.draft, "")   // fresh session, no stale draft
        // The stale scheduled tick from the first utterance must be a no-op.
        XCTAssertEqual(m.tick(now: 5.0).state, "recording")
    }

    func testEndpointProgressTrackedWhileRecording() {
        let m = make()
        _ = m.apply([.state: .state("recording", "recording (hands-free)")], now: 0.0)
        var vm = m.apply([.endpointProgress: .endpointProgress(0.6)], now: 1.0)
        XCTAssertEqual(vm.endpointFraction, 0.6)
        // a fresh utterance starts clean
        vm = m.apply([.state: .state("recording", "")], now: 2.0)
        XCTAssertEqual(vm.endpointFraction, 0.0)
    }

    func testCancelledResultFlashesBriefly() {
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.result: .result("cancelled", "")], now: 1.0)
        XCTAssertEqual(vm.state, "cancelled")
        XCTAssertTrue(vm.status.contains("cancelled"))
        XCTAssertNotNil(vm.hideAt)
        XCTAssertLessThan(vm.hideAt!, 1.0 + 1.4)   // shorter than done
    }

    func testIdleWhileRecordingHides() {
        // e.g. recording failed to start and the controller reset to idle
        let m = make()
        _ = m.apply([.state: .state("recording", "")], now: 0.0)
        let vm = m.apply([.state: .state("idle", "ready")], now: 0.5)
        XCTAssertFalse(vm.visible)
    }

    // MARK: - hudShouldShow (panel show-gate; regression for the intermittent HUD)

    func testShowOnHiddenToRecording() {
        XCTAssertTrue(hudShouldShow(state: "recording", prevState: "hidden"))
    }

    func testNoReshowWhileAlreadyRecording() {
        // Per-level present ticks during a live recording must not re-show.
        XCTAssertFalse(hudShouldShow(state: "recording", prevState: "recording"))
    }

    func testShowOnFreshRecordingWhilePriorFlashLingers() {
        // The bug: re-record before the previous done/error/cancelled flash
        // auto-hides. prevState is the flash, not "hidden" — the old
        // `prevState == "hidden"` gate skipped show() and the HUD never
        // reappeared. A fresh recording must re-show regardless.
        for flash in ["done", "error", "cancelled"] {
            XCTAssertTrue(hudShouldShow(state: "recording", prevState: flash),
                          "recording after \(flash) flash must re-show the HUD")
        }
    }

    func testNoShowForFinishingOrFlashStates() {
        // Continuations/flashes never trigger a fresh show on their own; the
        // panel is already up from the recording that preceded them.
        XCTAssertFalse(hudShouldShow(state: "transcribing", prevState: "recording"))
        XCTAssertFalse(hudShouldShow(state: "polishing", prevState: "transcribing"))
        XCTAssertFalse(hudShouldShow(state: "done", prevState: "polishing"))
    }
}
