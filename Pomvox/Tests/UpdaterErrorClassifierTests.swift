import XCTest
@testable import Pomvox

/// Update-failure → inline message mapping (design §Error handling). All
/// failures render as UI text, never a popup; verification/download failures
/// offer a manual-download link, translocation offers move-to-Applications
/// guidance.
final class UpdaterErrorClassifierTests: XCTestCase {

    func testTranslocationAsksToMoveToApplications() {
        let r = UpdaterErrorClassifier.classify(
            domain: "SUSparkleErrorDomain", code: 4001,
            localizedDescription: "The application is translocated and cannot be updated in place.")
        XCTAssertTrue(r.message.contains("Applications folder"))
        XCTAssertFalse(r.offerManualDownload, "moving the app fixes it — no manual-download link")
    }

    func testVerificationFailureOffersManualDownload() {
        let r = UpdaterErrorClassifier.classify(
            domain: "SUSparkleErrorDomain", code: 4004,
            localizedDescription: "The update is improperly signed and could not be verified.")
        XCTAssertEqual(r.message, "This update couldn't be verified.")
        XCTAssertTrue(r.offerManualDownload)
    }

    func testNetworkFailureSuggestsCheckingConnection() {
        let r = UpdaterErrorClassifier.classify(
            domain: "NSURLErrorDomain", code: -1009,
            localizedDescription: "The Internet connection appears to be offline.")
        XCTAssertTrue(r.message.contains("connection"))
        XCTAssertFalse(r.offerManualDownload)
    }

    func testFallbackKeepsSparkleDescriptionAndOffersManual() {
        let r = UpdaterErrorClassifier.classify(
            domain: "SUSparkleErrorDomain", code: 2001,
            localizedDescription: "The update archive could not be extracted.")
        XCTAssertEqual(r.message, "The update archive could not be extracted.")
        XCTAssertTrue(r.offerManualDownload)
    }

    func testEmptyDescriptionFallsBackToAGenericMessage() {
        let r = UpdaterErrorClassifier.classify(domain: "X", code: 0, localizedDescription: "")
        XCTAssertFalse(r.message.isEmpty)
        XCTAssertTrue(r.offerManualDownload)
    }
}
