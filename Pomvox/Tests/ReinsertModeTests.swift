import XCTest
@testable import Pomvox

/// The only pure decision in re-insert: granted → synthesized paste, not
/// granted → copy-only fallback. The CGEvent side effect itself is integration,
/// exercised in the on-device walkthrough.
final class ReinsertModeTests: XCTestCase {
    func testGrantedUsesPaste() {
        XCTAssertEqual(ReinsertMode.decide(trusted: true), .paste)
    }
    func testNotGrantedFallsBackToCopy() {
        XCTAssertEqual(ReinsertMode.decide(trusted: false), .copyOnly)
    }
}
