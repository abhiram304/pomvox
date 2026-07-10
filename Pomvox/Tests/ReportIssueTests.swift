import XCTest
@testable import Pomvox

/// The "Report an Issue" mailto builder: pure fields → URL, so the encoding and
/// the empty-field handling are pinned without needing a mail client.
final class ReportIssueTests: XCTestCase {

    func testRecipientIsTheMaintainerInbox() {
        XCTAssertEqual(ReportIssue.recipient, "hello@pomvox.ai")
    }

    func testEmptyFieldsProduceABareMailto() {
        let url = ReportIssue.mailtoURL(subject: "", body: "")
        XCTAssertEqual(url?.absoluteString, "mailto:hello@pomvox.ai",
                       "empty subject/body → composer opens blank, no query")
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
