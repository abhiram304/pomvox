import XCTest
@testable import Pomvox

/// The explicit low-memory cleanup prompt (item 7): the pure show/don't-show
/// decision that replaces PR #65's silent skip.
final class LowMemoryCleanupTests: XCTestCase {

    func testPromptsOnLowMemoryWhenUndecidedAndNotYetAsked() {
        XCTAssertTrue(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: true, cleanupKeyPresent: false, alreadyPrompted: false))
    }

    func testNeverPromptsOnAmpleMemory() {
        XCTAssertFalse(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: false, cleanupKeyPresent: false, alreadyPrompted: false))
    }

    func testNeverPromptsWhenTheUserAlreadyChose() {
        // An explicit [cleanup] enabled key means the user has decided.
        XCTAssertFalse(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: true, cleanupKeyPresent: true, alreadyPrompted: false))
    }

    func testNeverPromptsTwice() {
        XCTAssertFalse(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: true, cleanupKeyPresent: false, alreadyPrompted: true))
    }
}
