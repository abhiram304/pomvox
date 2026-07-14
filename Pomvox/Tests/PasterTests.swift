import AppKit
import XCTest
@testable import Pomvox

/// The paste/clipboard-recovery policy. The synthesized ⌘V and the AX focus probe
/// can't be unit-tested, so `Paster.deliver` takes them as injected closures +
/// flag; this exercises the clipboard staging, restore-guard, and no-focus
/// fallback against a real (named, off-general) pasteboard.
final class PasterTests: XCTestCase {

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("app.pomvox.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testFocusedFieldStagesTextThenRestoresPriorClipboard() {
        let pb = freshPasteboard()
        pb.clearContents(); pb.setString("old", forType: .string)

        var synthesized = false
        var restore: (() -> Void)?
        let outcome = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                                     synthesizePaste: { synthesized = true },
                                     scheduleRestore: { restore = $0 })

        XCTAssertEqual(outcome, .pasted)
        XCTAssertTrue(synthesized)
        XCTAssertEqual(pb.string(forType: .string), "dictated")  // staged for the ⌘V
        restore?()                                               // the delayed restore fires
        XCTAssertEqual(pb.string(forType: .string), "old")       // prior clipboard back
    }

    func testNoFocusLeavesTranscriptOnClipboardInsteadOfLosingIt() {
        let pb = freshPasteboard()
        pb.clearContents(); pb.setString("old", forType: .string)

        var restoreScheduled = false
        let outcome = Paster.deliver("dictated", to: pb, focusedAcceptsText: false,
                                     synthesizePaste: {},
                                     scheduleRestore: { _ in restoreScheduled = true })

        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertFalse(restoreScheduled)                         // no restore → keep it
        XCTAssertEqual(pb.string(forType: .string), "dictated")  // recoverable, not lost
    }

    /// Regression guard for the intermittent "pastes previous text" bug: the
    /// restore must not fire so soon that a slow-to-paste app reads the restored
    /// prior clipboard instead of the staged transcript. 0.15 s was too short;
    /// pin the floor to the chosen 0.5 s so it can't be shortened back into the
    /// race — a *longer* delay stays safe (it only widens the recovery window).
    func testRestoreDelayIsGenerousEnoughToOutlastASlowPaste() {
        XCTAssertGreaterThanOrEqual(Paster.restoreDelay, 0.5)
    }

    func testRestoreYieldsToARealUserCopyDuringTheDelay() {
        let pb = freshPasteboard()
        pb.clearContents(); pb.setString("old", forType: .string)

        var restore: (() -> Void)?
        _ = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                           synthesizePaste: {}, scheduleRestore: { restore = $0 })
        pb.clearContents(); pb.setString("user copied this", forType: .string)  // real copy lands
        restore?()
        XCTAssertEqual(pb.string(forType: .string), "user copied this")  // user copy wins
    }
}
