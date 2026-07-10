import XCTest
@testable import Pomvox

/// The "Report an issue" mailto builder: pure fields → URL, so the encoding and
/// the empty-field handling are pinned without needing a mail client.
final class ReportIssueTests: XCTestCase {

    func testRecipientIsTheMaintainerInbox() {
        XCTAssertEqual(ReportIssue.recipient, "hello@pomvox.ai")
    }

    func testDefaultOpensABareMailto() {
        // The settings button passes no subject/body: the composer opens blank.
        let url = ReportIssue.mailtoURL()
        XCTAssertEqual(url?.absoluteString, "mailto:hello@pomvox.ai")
    }

    func testSubjectAndBodyAreCarriedAndEncoded() {
        let url = ReportIssue.mailtoURL(subject: "app crash", body: "line one")
        let s = url?.absoluteString ?? ""
        XCTAssertTrue(s.hasPrefix("mailto:hello@pomvox.ai?"), "got \(s)")
        XCTAssertTrue(s.contains("subject=app%20crash"), "subject must be percent-encoded: \(s)")
        XCTAssertTrue(s.contains("body=line%20one"), "body must be percent-encoded: \(s)")
    }

    func testOnlyNonEmptyFieldsAppearInTheQuery() {
        let url = ReportIssue.mailtoURL(subject: "", body: "just a note")
        let s = url?.absoluteString ?? ""
        XCTAssertFalse(s.contains("subject="), "an empty subject is omitted: \(s)")
        XCTAssertTrue(s.contains("body=just%20a%20note"), "got \(s)")
    }
}
